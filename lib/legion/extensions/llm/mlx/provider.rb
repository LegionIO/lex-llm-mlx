# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Mlx
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

        # Capability config helpers — mix into Provider.
        module CapabilityConfig
          private

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
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.provider.instance_capability_config')
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
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'mlx.fetch_models_config')
            nil
          end
        end

        # Health payload helpers — mix into Provider.
        module HealthHelpers
          private

          def health_payload(raw)
            ready = health_ready?(raw)
            status = health_status(ready)
            {
              provider: :mlx,
              instance_id: provider_instance_id,
              status: status,
              ready: ready,
              circuit_state: circuit_state(status),
              raw: raw
            }
          end

          def health_ready?(raw)
            raw.is_a?(Hash) ? raw.fetch('ready', raw.fetch(:ready, true)) : true
          end

          def health_status(ready)
            ready ? 'healthy' : 'unhealthy'
          end

          def circuit_state(status)
            status == 'healthy' ? 'closed' : 'open'
          end
        end

        # Capability resolution helpers — mix into Provider.
        module CapabilityResolution
          private

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

          def extract_catalog_capabilities(_model_info)
            # Regex-based name matching is not authoritative evidence.
            # Unverified capability support is unknown, not promoted to supported.
            {}
          end

          def embedding_model?(model_id)
            model_id.to_s.match?(/embed|bge|e5|nomic/i)
          end

          def provider_envelope_capabilities
            # No capabilities are advertised at the envelope level without endpoint evidence.
            {}
          end

          def offering_metadata_for(model_info)
            {
              raw_model: model_info.id,
              parameter_count: model_info.respond_to?(:parameter_count) ? model_info.parameter_count : nil,
              quantization: model_info.respond_to?(:quantization) ? model_info.quantization : nil
            }.compact
          end
        end

        # MLX provider implementation for local OpenAI-compatible servers.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include CapabilityConfig
          include HealthHelpers
          include CapabilityResolution

          class << self
            def slug = 'mlx'
            def local? = true
            def default_transport = :http
            def default_tier = :local
            def configuration_options = %i[mlx_api_base mlx_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities
          end

          def settings
            Mlx.default_settings
          end

          def api_base
            normalize_url(config.mlx_api_base || settings[:instances][:default][:endpoint])
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
            raw = connection.get(health_url).body
            health_payload(raw)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'mlx.provider.health')
            {
              provider: :mlx,
              instance_id: provider_instance_id,
              status: 'unhealthy',
              ready: false,
              circuit_state: 'open',
              error: e.class.name,
              message: e.message
            }
          end

          def readiness(live: false)
            log.info("Checking MLX readiness (live=#{live})")
            super
          end

          def list_models(**)
            log.info('Listing available MLX models')
            models = super
            log.info("Discovered #{Array(models).size} MLX models")
            models
          end

          def offering_from_model(model_info, health: {})
            policy = resolve_capability_policy(model_info)
            Legion::Extensions::Llm::Routing::ModelOffering.new(**build_offering_kwargs(
              model_info: model_info, policy: policy, health: health
            ))
          end

          private

          # Canonical boundary (N x N law): pipeline dispatch delivers
          # Canonical::Message objects; the provider-native Chat facade
          # delivers lex-llm Message. Both are object shapes the inherited
          # OpenAI-compatible render reads via .role/.content. Plain Hashes are
          # the bypass class (the 2026-08-19 incident) — reject loudly at the
          # render seam rather than letting them reach the inherited renderer
          # (NoMethodError) and mask the bypass.
          def render_payload(messages, **opts)
            enforce_render_message_boundary!(messages)
            super
          end

          def enforce_render_message_boundary!(messages)
            Array(messages).each do |msg|
              next if msg.is_a?(Legion::Extensions::Llm::Canonical::Message)
              next if msg.is_a?(Legion::Extensions::Llm::Message)

              raise ArgumentError,
                    "mlx provider input must be Canonical::Message objects, got #{msg.class} — " \
                    'non-canonical message shapes must not cross the dispatch boundary'
            end
          end

          def build_offering_kwargs(model_info:, policy:, health:)
            {
              provider_family: :mlx,
              instance_id: provider_instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model_info.id,
              canonical_model_alias: model_info.respond_to?(:name) ? model_info.name : nil,
              model_family: model_info.respond_to?(:family) ? model_info.family : nil,
              usage_type: embedding_model?(model_info.id) ? :embedding : :inference,
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: extract_model_limits(model_info),
              health: health,
              metadata: offering_metadata_for(model_info).merge(capability_sources: policy[:sources])
            }
          end

          def extract_model_limits(model_info)
            ctx = model_info.respond_to?(:context_length) ? model_info.context_length : nil
            { context_window: ctx }.compact
          end
        end
      end
    end
  end
end
