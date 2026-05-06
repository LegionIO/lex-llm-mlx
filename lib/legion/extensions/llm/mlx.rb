# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/mlx/provider'
require 'legion/extensions/llm/mlx/version'

module Legion
  module Extensions
    module Llm
      # Mlx provider extension namespace.
      module Mlx
        extend Legion::Logging::Helper
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
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
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 1,
                queue_suffix: nil
              }
            }
          )
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances
          instances = {}
          discover_local_instance(instances)
          discover_settings_instances(instances)
          instances
        end

        def self.discover_local_instance(instances)
          return unless CredentialSources.socket_open?('localhost', 8080, timeout: 0.1)

          instances[:local] = {
            base_url: 'http://localhost:8080',
            tier: :local,
            capabilities: [:completion]
          }
        end

        def self.discover_settings_instances(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :mlx, :instances)
          return unless cfg.is_a?(Hash)

          cfg.each do |name, config|
            instances[name.to_sym] = normalize_instance_config(config).merge(tier: :direct)
          end
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:mlx_api_base] ||= normalized.delete(:base_url)
          normalized[:mlx_api_base] ||= normalized.delete(:api_base)
          normalized[:mlx_api_base] ||= normalized.delete(:endpoint)
          normalized[:mlx_api_key] ||= normalized.delete(:api_key)
          normalized[:mlx_api_base] = normalize_api_base(normalized[:mlx_api_base]) if normalized[:mlx_api_base]
          normalized.compact
        end

        def self.normalize_api_base(url)
          url.to_s.sub(%r{/v1/?\z}, '')
        end

        private_class_method :discover_local_instance, :discover_settings_instances,
                             :normalize_instance_config, :normalize_api_base

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end

Legion::Extensions::Llm::Mlx.register_discovered_instances
