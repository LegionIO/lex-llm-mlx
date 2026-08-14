# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Mlx
        module Actor
          # Evidence and offering-draft construction — included by DiscoveryRefresh.
          module EvidenceBuilding
            EMBEDDING_PATTERN = /embed|bge|e5|nomic/i
            # Protocol-required evidence source: the default_false taxonomy member.
            UNKNOWN_EVIDENCE_SRC = :default_false

            private

            def embedding_model?(model_id:)
              model_id.to_s.match?(EMBEDDING_PATTERN)
            end

            def build_offering_draft(model_id:, model_data:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :local
              embed_supported = embedding_model?(model_id: model_id)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(embed_supported: embed_supported, model_id: model_id),
                capability_evidence: build_capability_evidence(model_id: model_id),
                context_evidence: build_context_evidence(model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  model_data: model_data, embed_supported: embed_supported
                ),
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_data: model_data, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            def build_operation_evidence(embed_supported:, **)
              now = Time.now.freeze
              is_embedding = embed_supported
              {
                chat: op_evidence(operation: :chat, status: is_embedding ? :unsupported : :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: is_embedding ? :unsupported : :supported,
                                         observed_at: now),
                embed: op_evidence(operation: :embed, status: is_embedding ? :supported : :unsupported,
                                   observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? UNKNOWN_EVIDENCE_SRC : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(model_id:)
              is_embedding = embedding_model?(model_id: model_id)
              caps = {
                completion: cap_evidence(capability: :completion,
                                         status: is_embedding ? :unsupported : :supported,
                                         source: :provider_implementation),
                streaming: cap_evidence(capability: :streaming,
                                        status: is_embedding ? :unsupported : :supported,
                                        source: :provider_implementation),
                tools: cap_evidence(capability: :tools, status: :unknown, source: UNKNOWN_EVIDENCE_SRC),
                thinking: cap_evidence(capability: :thinking, status: :unknown, source: UNKNOWN_EVIDENCE_SRC)
              }

              if is_embedding
                caps[:embedding] = cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              end

              caps
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end
          end

          # Value-level evidence builders (context, output, dimensions, metadata) — included by DiscoveryRefresh.
          module ValueEvidenceBuilding
            private

            def build_context_evidence(model_data:)
              ctx = model_data[:max_model_len] || model_data[:context_length]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:max_output_tokens] || model_data[:max_completion_tokens]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def build_embedding_dimensions_evidence(model_data:, embed_supported:)
              unless embed_supported
                return Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end

              dims = model_data[:embedding_dimensions]
              if dims.is_a?(Array) && !dims.empty? && dims.all? { |d| d.is_a?(Integer) && d.positive? }
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims.uniq.sort, source: :provider_catalog
                )
              else
                absent_value_evidence
              end
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: model_data[:id].to_s }
              meta[:parameter_count] = model_data[:parameter_count] if model_data[:parameter_count]
              meta[:quantization] = model_data[:quantization].to_s if model_data[:quantization]
              meta[:instance_id] = instance_key.instance_id
              meta
            end
          end

          # Model-discovery and offering-assembly — included by DiscoveryRefresh.
          module OfferingAssembly
            private

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)

              models.filter_map do |model_data|
                model_id = model_data[:id].to_s
                next if model_id.empty?

                build_offering_draft(
                  model_id: model_id, model_data: model_data,
                  instance_cfg: instance_cfg, instance_key: instance_key
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:mlx_api_base] || instance_cfg[:endpoint])
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('/v1/models')
              Legion::JSON.load(response.body).fetch(:data, [])
            end
          end

          # Health checking and readiness probe lifecycle — included by DiscoveryRefresh.
          module HealthProbing
            private

            def check_health(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:mlx_api_base] || instance_cfg[:endpoint])
              conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('/health')
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.actor.check_health')
              readiness_failure(reason: "MLX /health connection failed: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.actor.check_health')
              readiness_failure(reason: "MLX /health error: #{e.message}", error: e)
            end

            def build_readiness_from_response(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "MLX /health returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: reason,
                metadata: { error_class: error.class.name }
              )
            end

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'mlx.actor.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'mlx.actor.cadence_probe', instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'mlx.actor.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'mlx.actor.reactive_probe', instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id, probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.probe_enqueue', instance_id: instance_id)
                false
              end
            end
          end

          # Periodic refresh cycle — included by DiscoveryRefresh.
          module TickCycle
            private

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id, publisher_token: state[:publisher_token],
                  offerings: new_offerings, sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end
          end

          # Instance configuration, ID derivation and settings — included by DiscoveryRefresh.
          module InstanceConfig
            private

            def settings
              Legion::Settings[:extensions][:llm][:mlx]
            end

            def configured_instances
              instances = {}
              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end

              if instances.empty?
                instances[:local] = {
                  mlx_api_base: settings[:endpoint],
                  tier: :local,
                  mlx_api_key: settings[:credentials][:api_key]
                }
              end

              instances
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              resolve_api_base(normalized: normalized)
              resolve_instance_credentials(normalized: normalized)
              normalized[:tier] ||= :local
              normalized
            end

            def resolve_api_base(normalized:)
              normalized[:mlx_api_base] ||= normalized.delete(:base_url)
              normalized[:mlx_api_base] ||= normalized.delete(:api_base)
              normalized[:mlx_api_base] ||= normalized.delete(:endpoint)
              return unless normalized[:mlx_api_base]

              normalized[:mlx_api_base] = normalized[:mlx_api_base].to_s.sub(%r{/v1/?\z}, '')
            end

            def resolve_instance_credentials(normalized:)
              creds = normalized.delete(:credentials)
              return unless creds.is_a?(Hash)

              creds = creds.transform_keys(&:to_sym)
              normalized[:mlx_api_key] ||= creds[:api_key]
            end

            def derive_instance_id(instance_cfg:)
              base_url = instance_cfg[:mlx_api_base] || instance_cfg[:endpoint] || 'http://localhost:8000'
              host_port = extract_host_port(url: base_url)
              api_key = instance_cfg[:mlx_api_key] || instance_cfg.dig(:credentials, :api_key)

              if api_key.is_a?(String) && !api_key.strip.empty?
                fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 6]
                "#{host_port}/ak:#{fingerprint}"
              else
                host_port
              end
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || 'localhost'
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.extract_host_port', url: url.to_s)
              raise
            end

            def build_instance_key(instance_id:)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :mlx, instance_id: instance_id
              )
            end

            def build_probe_coordinator(instance_id:, instance_key:)
              Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )
            end

            def build_instance_state(**attrs)
              attrs.merge(sequence: 0)
            end
          end

          # HTTP connection builders — included by DiscoveryRefresh.
          module HttpConnections
            private

            def normalize_api_base(url)
              (url || 'http://localhost:8000').to_s.sub(%r{/v1/?\z}, '')
            end

            def build_health_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 5
                f.options.open_timeout = 3
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def build_api_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def apply_auth_header(faraday:, instance_cfg:)
              api_key = instance_cfg[:mlx_api_key] || instance_cfg.dig(:credentials, :api_key)
              return unless api_key.is_a?(String) && !api_key.strip.empty?

              faraday.headers['Authorization'] = "Bearer #{api_key}"
            end
          end

          # SSOT v3 periodic discovery actor for MLX provider instances.
          # Claims instances, discovers models via /v1/models, probes health
          # via /health, and publishes complete OfferingDraft snapshots through
          # the Inventory::Publisher. Supports coalesced reactive probes after
          # dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper
            include EvidenceBuilding
            include ValueEvidenceBuilding
            include OfferingAssembly
            include HealthProbing
            include TickCycle
            include InstanceConfig
            include HttpConnections

            def self.every_seconds = 60

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              settings[:discovery_interval] || self.class.every_seconds
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.discovery_refresh.shutdown')
            end

            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
            end

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              instance_key = build_instance_key(instance_id: instance_id)
              callable = MlxCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = build_probe_coordinator(instance_id: instance_id, instance_key: instance_key)
              publisher_token = publisher.claim_instance(
                instance_id: instance_id, callable: callable, probe_request_handle: probe_coordinator
              )
              run_activation(
                instance_id: instance_id, publisher_token: publisher_token,
                instance_desc: { name: name, instance_key: instance_key, instance_cfg: instance_cfg,
                                 callable: callable, probe_coordinator: probe_coordinator }
              )
            end

            def run_activation(instance_id:, publisher_token:, instance_desc:)
              instance_cfg = instance_desc[:instance_cfg]
              instance_key = instance_desc[:instance_key]
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              probe_token = publisher.readiness_probe_started(instance_id: instance_id,
                                                              publisher_token: publisher_token)
              readiness = check_health(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id, publisher_token: publisher_token,
                  offerings: offerings, sequence: 0, probe_token: probe_token
                )
              else
                publisher.readiness_failed(instance_id: instance_id, probe_token: probe_token,
                                           reason: readiness.reason)
              end

              @instance_states[instance_id] = build_instance_state(
                **instance_desc, publisher_token: publisher_token, offerings: offerings
              )
            end

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id, publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end
          end

          # Callable wrapper for an MLX provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class MlxCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[mlx][callable] disconnected' }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]
              kind = classify_error_kind(error: error)

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_error_kind(error:)
              case error
              when Faraday::ConnectionFailed then :connection_failure
              when Faraday::TimeoutError then :timeout
              when Faraday::ClientError then classify_client_error(error: error)
              when Faraday::ServerError then classify_server_error(error: error)
              when Legion::Extensions::Llm::OverloadedError then :overloaded
              else :provider_error
              end
            end

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/529/5xx as instance_unavailable by status alone.
              # Only an explicit flat MLX service/instance-unavailable signal (which MLX
              # does not produce) would justify instance_unavailable. For MLX, connection
              # failure (port unreachable) is the signal the instance is down.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end
