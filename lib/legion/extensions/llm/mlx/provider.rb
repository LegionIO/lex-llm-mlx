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

        # MLX provider implementation for local OpenAI-compatible servers.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible
          include HealthHelpers

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
        end
      end
    end
  end
end
