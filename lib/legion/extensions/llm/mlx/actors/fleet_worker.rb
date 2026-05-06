# frozen_string_literal: true

require 'legion/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Mlx
        module Actor
          # Subscription actor for MLX fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            def runner_class
              'Legion::Extensions::Llm::Mlx::Runners::FleetWorker'
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::LLM::Fleet::ProviderResponder.enabled_for?(Mlx.discover_instances)
            end
          end
        end
      end
    end
  end
end
