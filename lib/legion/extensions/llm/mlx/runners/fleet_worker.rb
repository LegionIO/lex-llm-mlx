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
          #
          # The fleet Subscription actor dispatches this as
          # `handle_fleet_request(**message)`, where message is the decoded
          # request envelope merged with transport metadata, so the
          # signature is kwargs-only. Ack/reject is owned by the
          # Subscription actor, so the responder is called with nil
          # delivery/properties.
          module FleetWorker
            include Legion::Logging::Helper
            extend Legion::Logging::Helper

            module_function

            def handle_fleet_request(**message)
              log.debug do
                "handling MLX fleet request request_id=#{message[:request_id].inspect} " \
                  "provider_instance=#{message[:provider_instance].inspect} " \
                  "operation=#{message[:operation].inspect}"
              end
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: message,
                provider_family: Mlx::PROVIDER_FAMILY,
                registry: Legion::Extensions::Llm::Inventory::Registry,
                delivery: nil,
                properties: nil
              )
            end
          end
        end
      end
    end
  end
end
