# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/mlx'
require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Mlx
        module Runners
          # Runner entrypoint for MLX fleet request execution.
          # Delegates to the shared ProviderResponder with exact-offering
          # registry support for SSOT v3 execution contracts.
          module FleetWorker
            include Legion::Logging::Helper
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              log.debug do
                "handling MLX fleet request request_id=#{payload_field(payload, :request_id).inspect} " \
                  "provider_instance=#{payload_field(payload, :provider_instance).inspect} " \
                  "operation=#{payload_field(payload, :operation).inspect}"
              end
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Mlx::PROVIDER_FAMILY,
                provider_class: Mlx::Provider,
                provider_instances: -> { Mlx.discover_instances },
                registry: Legion::Extensions::Llm::Inventory::Registry,
                delivery: delivery,
                properties: properties
              )
            end

            def payload_field(payload, key)
              return unless payload.respond_to?(:[])

              payload[key] || payload[key.to_s]
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.fleet_worker.payload_field',
                                  field: key)
              nil
            end
          end
        end
      end
    end
  end
end
