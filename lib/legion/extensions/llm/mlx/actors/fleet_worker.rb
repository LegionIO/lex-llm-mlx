# frozen_string_literal: true

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for MLX fleet worker'
end

require 'legion/extensions/llm/mlx'
require 'legion/extensions/llm/fleet/provider_responder'

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
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(Mlx.discover_instances)
            end
          end
        end
      end
    end
  end
end
