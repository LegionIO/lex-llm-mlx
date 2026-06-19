# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Mlx
        # MLX provider implementation for local OpenAI-compatible servers.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
          include Legion::Extensions::Llm::Provider::OpenAICompatible

          class << self
            attr_writer :registry_publisher

            def slug = 'mlx'
            def local? = true
            def default_transport = :http
            def default_tier = :local
            def configuration_options = %i[mlx_api_base mlx_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities

            def registry_publisher
              @registry_publisher ||= Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :mlx)
            end
          end

          # Conservative capability predicates for local MLX OpenAI-compatible servers.
          module Capabilities
            module_function

            def chat?(model) = !embeddings?(model)
            def streaming?(model) = chat?(model)
            def vision?(model) = model_id(model).match?(/vlm|vision|llava|pixtral|qwen.*vl/i)
            def functions?(model) = chat?(model)
            def embeddings?(model) = model_id(model).match?(/embed|bge|e5|nomic/i)

            def critical_capabilities_for(model)
              [
                ('streaming' if streaming?(model)),
                ('function_calling' if functions?(model)),
                ('vision' if vision?(model)),
                ('embeddings' if embeddings?(model))
              ].compact
            end

            def model_id(model)
              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end
          end

          def settings
            Mlx.default_settings
          end

          def api_base
            normalize_url(config.mlx_api_base || settings[:endpoint] || 'http://localhost:8000')
          end

          def headers
            hdrs = identity_headers
            token = config.mlx_api_key
            hdrs['Authorization'] = "Bearer #{token}" unless token.nil? || token.to_s.empty?
            hdrs
          end

          def health_url = '/health'

          def health(live: false)
            log.info("Checking MLX health live=#{live} at #{api_base}#{health_url}")
            connection.get(health_url).body
          end

          def readiness(live: false)
            log.info("Checking MLX readiness (live=#{live})")
            super.tap do |metadata|
              self.class.registry_publisher.publish_readiness_async(metadata) if live
            end
          end

          def list_models(**)
            log.info('Listing available MLX models')
            super.tap do |models|
              log.info("Discovered #{Array(models).size} MLX models")
              self.class.registry_publisher.publish_models_async(models, readiness: readiness(live: false))
            end
          end

          def discover_offerings(live: false, **)
            models = if live
                       @cached_models = list_models
                     else
                       Array(@cached_models)
                     end
            offerings = models.filter_map { |model_info| offering_from_model(model_info) }
            log.debug { "[llm][mlx] discover_offerings action=built count=#{offerings.size} live=#{live}" }
            offerings
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'mlx.discover_offerings')
            []
          end

          private

          def offering_from_model(model_info) # rubocop:disable Metrics/AbcSize
            policy = resolve_capability_policy(model_info)
            ctx = model_info.respond_to?(:context_length) ? model_info.context_length : nil

            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :mlx,
              instance_id: config.respond_to?(:instance_id) ? config.instance_id : :default,
              transport: :http,
              tier: :local,
              model: model_info.id,
              canonical_model_alias: model_info.respond_to?(:name) ? model_info.name : nil,
              model_family: model_info.respond_to?(:family) ? model_info.family : nil,
              usage_type: embedding_model?(model_info.id) ? :embedding : :inference,
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: { context_window: ctx }.compact,
              metadata: offering_metadata_for(model_info).merge(capability_sources: policy[:sources])
            )
          end

          def resolve_capability_policy(model_info)
            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: extract_real_capabilities(model_info),
              provider_catalog: extract_catalog_capabilities(model_info),
              probe: {},
              provider_envelope: provider_envelope_capabilities,
              provider_config: provider_capability_config,
              instance_config: instance_capability_config,
              model_config: model_capability_config(model_info.id)
            )
          end

          def extract_real_capabilities(model_info)
            return {} unless model_info.respond_to?(:metadata)

            meta = model_info.metadata
            return {} unless meta.is_a?(Hash)

            caps = meta[:capabilities]
            caps.is_a?(Hash) ? caps : {}
          end

          def extract_catalog_capabilities(model_info)
            model_id = model_info.respond_to?(:id) ? model_info.id.to_s : model_info.to_s
            caps = {}
            caps[:embeddings] = true if model_id.match?(/embed|bge|e5|nomic/i)
            caps[:vision] = true if model_id.match?(/vlm|vision|llava|pixtral|qwen.*vl/i)
            caps[:streaming] = true unless caps[:embeddings]
            caps
          end

          def embedding_model?(model_id)
            model_id.to_s.match?(/embed|bge|e5|nomic/i)
          end

          def provider_envelope_capabilities
            { streaming: true }
          end

          def provider_capability_config
            conf = Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, :mlx)
            conf.is_a?(Hash) ? conf.to_h.except(:instances, 'instances') : {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'mlx.provider_capability_config')
            {}
          end

          def instance_capability_config
            cfg = config
            result = {}
            %i[capabilities enable_thinking enable_tools enable_streaming enable_vision enable_embeddings
               thinking_flag tools_flag streaming_flag vision_flag embedding_flag embeddings_flag
               tool_flag images_flag image_flag].each do |key|
              next unless cfg.respond_to?(key)

              val = cfg.send(key)
              result[key] = val unless val.nil?
            rescue StandardError
              next
            end
            result
          end

          def model_capability_config(model_id)
            models_conf = fetch_models_config
            return {} unless models_conf

            hash = models_conf.to_h
            hash[model_id.to_s] || hash[model_id.to_sym] || {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'mlx.model_capability_config')
            {}
          end

          def fetch_models_config
            conf = config.models if config.respond_to?(:models)
            conf ||= config[:models] if config.respond_to?(:[])
            conf if conf.respond_to?(:to_h)
          rescue StandardError
            nil
          end

          def offering_metadata_for(model_info)
            {
              raw_model: model_info.id,
              parameter_count: model_info.respond_to?(:parameter_count) ? model_info.parameter_count : nil,
              quantization: model_info.respond_to?(:quantization) ? model_info.quantization : nil
            }.compact
          end
        end
      end
    end
  end
end
