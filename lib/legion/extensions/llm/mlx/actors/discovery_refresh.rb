# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Mlx
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Style/Documentation, Metrics/ClassLength
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            REFRESH_INTERVAL = 1800

            def self.every_seconds = 60

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :mlx, :discovery_interval) || REFRESH_INTERVAL
            end

            def scope_key(**)
              { provider: :mlx }
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              mlx_instances.flat_map { |entry| lanes_for_instance(entry) }
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.discovery_refresh.compute_lanes')
              []
            end

            def credential_hash(**)
              mlx_settings = Legion::Settings.dig(:extensions, :llm, :mlx) || {}
              Digest::SHA256.hexdigest(mlx_settings[:api_key].to_s + mlx_settings[:instances].to_s)[0, 16]
            end

            def manual(**)
              tick if respond_to?(:tick)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.actor.discovery_refresh')
            end

            private

            def mlx_instances
              Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :mlx
              end
            end

            def offerings_for(adapter, instance_id)
              Array(adapter.discover_offerings(live: true))
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'mlx.discovery_refresh.discover_offerings',
                                  instance: instance_id)
              []
            end

            def lanes_for_instance(entry)
              adapter     = entry[:adapter]
              instance_id = entry[:instance]
              return [] unless adapter.respond_to?(:discover_offerings)

              offerings_for(adapter, instance_id).filter_map do |offering|
                next if offering.nil?

                build_lanes(offering, instance_id)
              end.flatten
            end

            def build_lanes(offering, instance_id)
              type = offering_type(offering[:type])
              tier = offering[:tier] || :local
              lane = build_lane(offering, instance_id, type, tier)
              lanes = [lane]
              lanes << fleet_lane(lane, instance_id, type) if fleet_enabled? && type == :inference
              lanes
            end

            def build_lane(offering, instance_id, type, tier)
              {
                id: compose_lane_id(tier: tier, instance_id: instance_id,
                                    type: type, model: offering[:model]),
                tier: tier,
                provider_family: :mlx,
                instance_id: instance_id,
                model: offering[:model],
                canonical_model_alias: offering[:canonical_model_alias],
                type: type,
                capabilities: normalize_capabilities(offering[:capabilities]),
                limits: offering[:limits] || {},
                enabled: offering.fetch(:enabled, true),
                cost: offering[:cost] || {}
              }
            end

            def fleet_lane(lane, instance_id, type)
              lane.merge(
                tier: :fleet,
                id: compose_lane_id(tier: :fleet, instance_id: instance_id,
                                    type: type, model: lane[:model])
              )
            end

            def offering_type(raw)
              %i[embed embedding].include?(raw.to_s.to_sym) ? :embedding : :inference
            end

            def normalize_capabilities(caps)
              return [] unless defined?(Legion::LLM::Inventory::Capabilities)

              Legion::LLM::Inventory::Capabilities.normalize(caps)
            end

            def compose_lane_id(tier:, instance_id:, type:, model:)
              Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(
                tier: tier, provider_family: :mlx, instance_id: instance_id,
                type: type, model: model
              )
            end

            def fleet_enabled?
              mlx_settings = Legion::Settings.dig(:extensions, :llm, :mlx) || {}
              mlx_settings.dig(:fleet, :dispatch, :enabled)
            end
          end
        end
      end
    end
  end
end
