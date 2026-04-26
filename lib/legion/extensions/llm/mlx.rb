# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/mlx/provider_settings'
require 'legion/extensions/llm/mlx/version'

module Legion
  module Extensions
    module Llm
      # Mlx provider extension namespace.
      module Mlx
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :mlx

        def self.default_settings
          ProviderSettings.build(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: nil,
              tier: :local,
              transport: :local,
              usage: { inference: true, embedding: false },
              limits: { concurrency: 1 }
            }
          )
        end
      end
    end
  end
end
