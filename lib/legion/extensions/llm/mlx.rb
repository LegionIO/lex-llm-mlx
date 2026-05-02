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
          {
            enabled: false,
            base_url: 'localhost:8000',
            default_model: nil,
            api_key: nil,
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 60,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
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
            instances[name.to_sym] = config.merge(tier: :direct)
          end
        end

        private_class_method :discover_local_instance, :discover_settings_instances
      end
    end
  end
end

Legion::Extensions::Llm::Mlx.register_discovered_instances
