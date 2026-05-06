# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/mlx/provider'

module Legion
  module Extensions
    module Llm
      module Mlx
        module Runners
          # Runner entrypoint for MLX fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Mlx::PROVIDER_FAMILY,
                provider_class: Mlx::Provider,
                provider_instances: -> { Mlx.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
