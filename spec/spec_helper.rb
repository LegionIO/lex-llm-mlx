# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

# Stub the actor base class before loading the MLX extension so that
# discovery_refresh.rb defines MlxCallable (which lives inside the
# `return unless defined?(Legion::Extensions::Actors::Every)` guard).
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def self.every_seconds = 60
        end
      end
    end
  end
end

require 'legion/extensions/llm/mlx'

# Load conformance kit from lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path)
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path, 'spec/legion/extensions/llm/conformance')
  Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f }
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
end
