# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/mlx/provider'
require 'legion/extensions/llm/mlx/version'
require 'legion/extensions/llm/mlx/actors/discovery_refresh'

module Legion
  module Extensions
    module Llm
      # Mlx provider extension namespace.
      module Mlx
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :mlx

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:8000',
              tier: :local,
              transport: :http,
              credentials: { api_key: nil },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 1 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed]
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        # Single source of truth for MLX instance discovery. The SSOT
        # discovery actor and the fleet responder both read this: only
        # operator-configured instances. No port-scanning, no fabricated
        # instances, no tier override.
        def self.discover_instances
          configured_instances
        end

        # Only instances the operator actually configured are claimable.
        # The synthetic instances.default section (provider_settings nests
        # the extension's own instance defaults there at boot) is skipped
        # with a once-per-boot warn while it is still the unmodified
        # extension default — an unconfigured phantom must never be
        # auto-registered, and a localhost endpoint is never a fallback
        # identity.
        def self.configured_instances
          provider_cfg = Legion::Settings.dig(:extensions, :llm, :mlx) || {}
          instances = {}
          cfg_instances = provider_cfg[:instances]
          if cfg_instances.is_a?(Hash)
            cfg_instances.each do |name, config|
              normalized = normalize_instance_config(config)
              instances[name.to_sym] = normalized
            end
          end
          instances
        end

        # The synthetic default is the extension's OWN registered instance
        # defaults (endpoint http://localhost:8000 + fleet/limits blocks),
        # deep-merged into instances.default by provider_settings. It is
        # "configured" only when the operator changed something — a
        # configured 'default' passes the provider layer and reaches the
        # claim path (v2 parity: 'default' is a plain instance label). ONE
        # predicate, TWO consumers: the actor's claim path (tick_refresh
        # iterates configured_instances into claim_and_activate_instance)
        # and the fleet responder (discover_instances → configured_instances)
        # both reach it through this single filter point — no drift.
        def self.unconfigured_default?(name:, normalized:)
          name.to_sym == :default && normalized == normalized_synthetic_default_instance
        end

        def self.normalized_synthetic_default_instance
          @normalized_synthetic_default_instance ||= normalize_instance_config(
            default_settings.dig(:instances, :default) || {}
          )
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys(&:to_sym)
          promote_api_base_aliases(normalized)
          normalized[:mlx_api_base] = normalize_api_base(normalized[:mlx_api_base]) if normalized[:mlx_api_base]
          normalized[:mlx_api_key] ||= normalized.delete(:api_key)
          resolve_instance_credentials(normalized)
          normalized[:tier] ||= :local
          normalized.compact
        end

        def self.promote_api_base_aliases(normalized)
          normalized[:mlx_api_base] ||= normalized.delete(:base_url)
          normalized[:mlx_api_base] ||= normalized.delete(:api_base)
          normalized[:mlx_api_base] ||= normalized.delete(:endpoint)
        end

        def self.normalize_api_base(url)
          url.to_s.sub(%r{/v1/?\z}, '')
        end

        def self.resolve_instance_credentials(normalized)
          creds = normalized.delete(:credentials)
          return unless creds.is_a?(Hash)

          normalized[:mlx_api_key] ||= creds.transform_keys(&:to_sym)[:api_key]
        end

        private_class_method :normalize_instance_config, :promote_api_base_aliases, :normalize_api_base,
                             :resolve_instance_credentials

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
