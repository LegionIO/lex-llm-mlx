# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/mlx/provider'
require 'legion/extensions/llm/mlx/registry_event_builder'
require 'legion/extensions/llm/mlx/registry_publisher'
require 'legion/extensions/llm/mlx/version'

module Legion
  module Extensions
    module Llm
      # Mlx provider extension namespace.
      module Mlx
        extend Legion::Logging::Helper
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :mlx

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'http://localhost:8000',
              tier: :local,
              transport: :local,
              usage: { inference: true, embedding: true },
              limits: { concurrency: 1 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Mlx::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Mlx::Provider)
Legion::Extensions::Llm::Mlx.log.info('Registered MLX provider as :mlx')
