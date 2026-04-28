# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Mlx
        # MLX provider implementation for local OpenAI-compatible servers.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Extensions::Llm::Provider::OpenAICompatible

          class << self
            def slug = 'mlx'
            def local? = true
            def configuration_options = %i[mlx_api_base mlx_api_key]
            def configuration_requirements = []
            def capabilities = Capabilities
          end

          # Conservative capability predicates for local MLX OpenAI-compatible servers.
          module Capabilities
            module_function

            def chat?(model) = !embeddings?(model)
            def streaming?(model) = chat?(model)
            def vision?(model) = model_id(model).match?(/vlm|vision|llava|pixtral|qwen.*vl/i)
            def functions?(_model) = true
            def embeddings?(model) = model_id(model).match?(/embed|bge|e5|nomic/i)

            def model_id(model)
              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end
          end

          def api_base
            config.mlx_api_base || 'http://localhost:8000'
          end

          def headers
            token = config.mlx_api_key
            return {} if token.nil? || token.to_s.empty?

            { 'Authorization' => "Bearer #{token}" }
          end

          def health_url = '/health'

          def health
            connection.get(health_url).body
          end
        end
      end
    end
  end
end
