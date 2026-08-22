# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

# Functional stand-in for the LegionIO `Legion::Extensions::Helpers::Lex`
# helper, for MLX specs. The shared base discovery actor
# (lex-llm discovery/actor.rb) `include`s this host helper; in a standalone
# provider spec env the gem's own spec_helper must supply it. Provides the REAL
# settings/log/handle_exception the provider runner and actor rely on, without
# loading the full LegionIO helper stack.
#
# The self-extend hook mirrors the real Lex so module-level runners
# (Runners::Discovery) get settings/log/handle_exception on the module — the
# pipeline is a mixed-in module that calls them at module level.
require 'legion/logging'
require 'legion/settings'

module Legion
  module Extensions
    module Helpers
      module Lex
        include Legion::Logging::Helper
        include Legion::Settings::Helper

        def self.included(base)
          base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
        end
      end
    end
  end
end

# Stub the actor base class before loading the MLX extension so that
# discovery.rb's empty subclass of the shared base actor loads (it lives
# inside the `return unless defined?(Legion::Extensions::Llm::Discovery::Actor)`
# guard, which the stubbed `Every` satisfies). The thin actor redefines
# nothing; specs drive the `Mlx::Runners::Discovery` module directly and never
# start a timer.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def self.spec_stub? = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/mlx'

# Load the SSOT v3 shared conformance examples from the lex-llm gem's
# spec/ directory (spec/ ships in the gem but is NOT on the load path).
# Only the shared examples file — the kit directory also contains
# lex-llm's own self-test specs, which do not belong in this suite.
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path, 'spec/legion/extensions/llm/conformance')
  require File.join(kit_path, 'ssot_provider_examples.rb')
  require File.join(kit_path, 'ssot_contract_examples.rb')
end

if defined?(Legion::Settings)
  s = Legion::Settings.loader.settings
  s[:extensions][:llm] ||= {}
  s[:extensions][:llm][:mlx] ||= {}
end

if defined?(Legion::Logging)
  null_logger = Logger.new(File::NULL)
  null_logger.level = Logger::DEBUG
  Legion::Logging.instance_variable_set(:@log, null_logger)
  Legion::Logging.instance_variable_set(
    :@current_settings,
    {
      level: :debug,
      format: :text,
      async: false,
      trace: false,
      trace_size: 0,
      extended: false,
      log_file: nil,
      log_stdout: false,
      include_pid: false,
      color: false
    }.freeze
  )
  Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)

  # Provider helpers dispatch through this tagged boundary; keep the full
  # file-directed RSpec run free of unrelated runtime log output.
  RSpec.configure do |config|
    config.before do
      allow(Legion::Logging).to receive(:emit_tagged)
    end
  end
end
