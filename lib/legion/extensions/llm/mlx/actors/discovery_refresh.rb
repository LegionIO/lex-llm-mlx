# frozen_string_literal: true

require 'digest'
require 'time'
require 'uri'
require 'faraday'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for MLX discovery refresh'
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/weight_reconciler'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/mlx/provider'

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
              weight_inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings,
                instance_key: instance_key,
                provider_native_key: model_id,
                model: model_id,
                tier: tier
              )

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
                publication_source: :provider_catalog,
                weight_inputs: weight_inputs,
                base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(weight_inputs)
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
          #
          # Rescue discipline (D16): only network and response-parse errors
          # are runtime conditions that may yield no offerings — an
          # unreachable /v1/models is a probe outcome, not a bug. Programming
          # errors (NameError/NoMethodError/ArgumentError) are NOT rescued
          # here: converting them to [] would publish zero offerings and make
          # a healthy instance invisible. They propagate to the per-instance
          # isolation in the tick, which logs and retries next tick.
          module OfferingAssembly
            private

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              fetch_models(instance_cfg: instance_cfg).filter_map do |model_data|
                next unless model_data.is_a?(Hash)

                model_id = model_data[:id].to_s
                next if model_id.empty?

                build_offering_draft(
                  model_id: model_id, model_data: model_data,
                  instance_cfg: instance_cfg, instance_key: instance_key
                )
              end
            end

            def fetch_models(instance_cfg:)
              base_url = normalize_api_base(instance_cfg[:mlx_api_base] || instance_cfg[:endpoint])
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              parsed = Legion::JSON.load(conn.get('/v1/models').body)
              data = parsed.is_a?(Hash) ? parsed[:data] : nil
              data.is_a?(Array) ? data : []
            rescue Faraday::Error, Legion::JSON::ParseError => e
              handle_exception(e, level: :warn, handled: true, operation: 'mlx.actor.fetch_models')
              []
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
                ready: false, reason:, metadata: { error_class: error.class.name }
              )
            end

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              commit_probe_result(
                instance_id: instance_id, physical_id: state[:physical_id],
                probe_token: probe_token, readiness: readiness, state: state
              )
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'mlx.actor.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'mlx.actor.cadence_probe', instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = state_mutex.synchronize { @instance_states[instance_id] }
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              perform_reactive_probe(
                instance_id: instance_id, request: request,
                state: state, coordinator: coordinator
              )
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_err
                handle_exception(finish_err, level: :warn, operation: 'mlx.actor.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'mlx.actor.reactive_probe', instance_id: instance_id)
            end

            def perform_reactive_probe(instance_id:, request:, state:, coordinator:)
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, physical_id: state[:physical_id],
                publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              commit_probe_result(
                instance_id: instance_id, physical_id: state[:physical_id],
                probe_token: probe_token, readiness: readiness, state: state
              )
            end

            def commit_probe_result(instance_id:, physical_id:, probe_token:, readiness:, state:)
              state_mutex.synchronize do
                return unless @instance_states[instance_id].equal?(state)

                if readiness.ready?
                  publisher.readiness_succeeded(
                    instance_id: instance_id, physical_id: physical_id, probe_token: probe_token
                  )
                else
                  publisher.readiness_failed(
                    instance_id: instance_id, physical_id: physical_id,
                    probe_token: probe_token, reason: readiness.reason
                  )
                end
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

          # MLX offering comparison excludes only evidence observation telemetry.
          module OfferingComparison
            OFFERING_SCALAR_EVIDENCE_FIELDS = %i[
              context_evidence max_output_evidence embedding_dimensions_evidence
              model_revision_evidence tokenizer_evidence
            ].freeze

            private

            # Inventory evidence timestamps are telemetry only: Evidence explicitly
            # excludes observed_at from authority, ordering, freshness, recovery, and
            # selection. Compare every OfferingDraft field (including the stored weight
            # pair) while removing only those volatile evidence timestamps.
            def offerings_equivalent?(previous, current)
              Array(previous).map { |draft| offering_comparison_state(draft) }.tally ==
                Array(current).map { |draft| offering_comparison_state(draft) }.tally
            end

            def offering_comparison_state(draft)
              state = draft.to_h
              state[:operation_evidence] = comparison_evidence_map(draft.operation_evidence)
              state[:capability_evidence] = comparison_evidence_map(draft.capability_evidence)
              OFFERING_SCALAR_EVIDENCE_FIELDS.each do |field|
                state[field] = comparison_evidence(draft.public_send(field))
              end
              state
            end

            def comparison_evidence_map(evidence)
              evidence.transform_values { |entry| comparison_evidence(entry) }
            end

            def comparison_evidence(evidence)
              evidence.to_h.except(:observed_at)
            end
          end

          # MLX bindings for the shared writer reconciler. This module owns only
          # actor-local publication synchronization and dormant tracking used by
          # the existing discovery cadence.
          module WeightPublication
            private

            def replace_offerings_if_changed(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state: state,
                discovered_offerings: new_offerings,
                mutex: state_mutex,
                equivalent: method(:offerings_equivalent?),
                replace: method(:replace_weight_snapshot)
              )
            end

            def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
              publisher.replace_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                physical_id: state.fetch(:physical_id)
              )
            end

            def commit_readiness(instance_id:, probe_token:, readiness:, state:)
              if readiness.ready?
                return Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                  settings: Legion::Settings,
                  instance_id: instance_id,
                  state_key: instance_id,
                  state: state,
                  states: @instance_states,
                  mutex: state_mutex,
                  probe_token: probe_token,
                  activate: method(:activate_weight_snapshot),
                  activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
                )
              end

              state_mutex.synchronize do
                return false unless @instance_states[instance_id].equal?(state)

                publisher.readiness_failed(
                  instance_id: instance_id, physical_id: state[:physical_id],
                  probe_token: probe_token, reason: readiness.reason
                )
              end
              true
            end

            def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
              publisher.activate_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                probe_token: probe_token,
                physical_id: state.fetch(:physical_id)
              )
            end

            def observe_dormant_weights
              Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                settings: Legion::Settings,
                provider_family: :mlx,
                states: @instance_states,
                mutex: state_mutex,
                tracker: dormant_weight_tracker,
                dormant_logger: lambda do |key|
                  log.info(
                    "[llm][mlx] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                  )
                end
              )
            end

            def state_mutex
              @state_mutex ||= Mutex.new
            end

            def dormant_weight_tracker
              @dormant_weight_tracker ||= Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
            end
          end

          # Periodic refresh cycle — included by DiscoveryRefresh. Each tick
          # re-scans the configured instances (late configuration appears
          # without a restart; removed instances are reconciled out),
          # re-activates instances still initializing after an initial
          # readiness failure, and refreshes offerings + cadence probes for
          # activated instances.
          module TickCycle
            private

            def tick_refresh
              instance_states
              configured_ids = {}
              configured_instances.each do |name, instance_cfg|
                reconcile_configured_instance(
                  name: name, instance_cfg: instance_cfg, configured_ids: configured_ids
                )
              end

              remove_unconfigured_instances(configured_ids: configured_ids)
              observe_dormant_weights
            end

            def instance_states
              state_mutex.synchronize { @instance_states ||= {} }
            end

            # Identity is the operator's config name — the key the frozen config
            # and router use. Two names at one endpoint remain distinct instances.
            def reconcile_configured_instance(name:, instance_cfg:, configured_ids:)
              instance_id = name.to_s
              configured_ids[instance_id] = true
              state = state_mutex.synchronize { @instance_states[instance_id] }
              if state.nil?
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              else
                refresh_instance(instance_id: instance_id, name: name, state: state)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.tick_refresh', instance_name: name.to_s)
            end

            def remove_unconfigured_instances(configured_ids:)
              states = state_mutex.synchronize { @instance_states.to_a }
              states.each do |instance_id, state|
                next if configured_ids.key?(instance_id)

                remove_instance_state(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.remove_instance_state',
                                    instance_id: instance_id)
              end
            end

            def remove_instance_state(instance_id:, state:)
              removed = state_mutex.synchronize do
                next false unless @instance_states[instance_id].equal?(state)

                publisher.remove_instance(
                  instance_id: instance_id, physical_id: state[:physical_id],
                  publisher_token: state[:publisher_token]
                )
                @instance_states.delete(instance_id)
                true
              end
              clear_instance_health(config_name: state[:name]) if removed
              removed
            end

            def refresh_instance(instance_id:, name:, state:)
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              if status.state == :initializing
                reactivate_if_ready(instance_id: instance_id, name: name, state: state)
                return
              end

              replace_offerings_if_changed(instance_id: instance_id, state: state)
              run_cadence_probe(instance_id: instance_id, state: state)
              write_instance_health(config_name: name, state: state)
            end

            # Initial-failure recovery: an instance stuck at :initializing
            # (readiness failed at boot, e.g. transient outage) re-activates
            # on the first healthy probe. While :initializing,
            # replace_instance_snapshot and readiness_succeeded are invalid
            # transitions — activate_instance_snapshot is the only legal
            # commit, so the cadence probe path is not usable here.
            def reactivate_if_ready(instance_id:, name:, state:)
              offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state: state,
                discovered_offerings: offerings,
                mutex: state_mutex,
                equivalent: method(:offerings_equivalent?),
                replace: method(:replace_weight_snapshot)
              )
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token]
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              committed = commit_readiness(
                instance_id: instance_id, probe_token: probe_token,
                readiness: readiness, state: state
              )
              write_instance_health(config_name: name, state: state) if committed
            end
          end

          # Instance configuration, ID derivation and settings — included by DiscoveryRefresh.
          module InstanceConfig
            private

            def settings
              Legion::Settings.dig(:extensions, :llm, :mlx) || {}
            end

            def configured_instances
              Legion::Extensions::Llm::Mlx.configured_instances
            end

            # The SECONDARY physical id (host:port, or host:port/ak:<fp>
            # when the instance is keyed). It is carried by InstanceKey
            # for dedup and diagnostics only — never identity. Identity
            # is the operator's config name (see tick_refresh).
            def derive_physical_id(instance_cfg:)
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

            def build_instance_key(instance_id:, physical_id:)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :mlx, instance_id: instance_id, physical_id: physical_id
              )
            end

            def build_probe_coordinator(instance_id:, instance_key:)
              Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )
            end

            def build_instance_state(**attrs)
              attrs.merge(sequence: 0, published: false)
            end
          end

          # Display-only health/capabilities written into the settings tree
          # after each registry commit. Routing authority stays in the
          # in-memory Registry; this hash exists so the status API
          # (legion-llm /api/llm/providers) renders per-instance health.
          # Keyed by the operator's config name, not the derived instance_id.
          module HealthDisplay
            HEALTH_SOURCE = :provider_probe

            private

            def write_instance_health(config_name:, state:)
              instance_settings = settings[:instances]
              return unless instance_settings.is_a?(Hash) && instance_settings[config_name].is_a?(Hash)

              instance_settings[config_name][:health] = build_health_hash(state: state)
              instance_settings[config_name][:capabilities] = build_display_capabilities(state: state)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.write_instance_health',
                                  instance_name: config_name.to_s)
            end

            def clear_instance_health(config_name:)
              instance_settings = settings[:instances]
              return unless instance_settings.is_a?(Hash) && instance_settings[config_name].is_a?(Hash)

              instance_settings[config_name].delete(:health)
              instance_settings[config_name].delete(:capabilities)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'mlx.actor.clear_instance_health',
                                  instance_name: config_name.to_s)
            end

            def build_health_hash(state:)
              instance_key = state[:instance_key]
              status = publisher.snapshot.publication_status(instance_key: instance_key)
              availability = publisher.snapshot.instance(instance_key: instance_key)&.availability
              {
                circuit_state: health_circuit_state(availability),
                denied: false,
                available: health_available?(availability),
                adjustment: health_adjustment(availability),
                reason: health_display_reason(status: status, availability: availability),
                observed_at: health_observed_at(status: status, availability: availability),
                last_probe_outcome: status.last_probe_outcome,
                source: HEALTH_SOURCE
              }
            end

            def health_available?(availability)
              !availability.nil? && availability.state == :available
            end

            def health_circuit_state(availability)
              health_available?(availability) ? :closed : :open
            end

            def health_adjustment(availability)
              health_available?(availability) ? 0 : -50
            end

            def health_observed_at(status:, availability:)
              # getutc (not utc): the registry freezes its Time objects, and
              # Time#utc mutates the receiver in place.
              (availability&.observed_at || status.last_probe_completed_at || Time.now).getutc.iso8601
            end

            def health_display_reason(status:, availability:)
              return availability.reason if availability&.reason
              return status.last_error if status.last_error

              'awaiting initial readiness'
            end

            def build_display_capabilities(state:)
              state[:offerings].each_with_object(Hash.new(false)) do |draft, supported|
                draft.capability_evidence.each do |capability, evidence|
                  supported[capability] = true if evidence.supported?
                end
              end.keys.sort
            end
          end

          # HTTP connection builders — included by DiscoveryRefresh.
          module HttpConnections
            private

            def normalize_api_base(url)
              (url || 'http://localhost:8000').to_s.sub(%r{/v1/?\z}, '')
            end

            def build_health_connection(base_url:, instance_cfg:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 5
                f.options.open_timeout = 3
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def build_api_connection(base_url:, instance_cfg:)
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
          # Claims configured instances, discovers models via /v1/models,
          # probes health via /health, and publishes complete OfferingDraft
          # snapshots through the Inventory::Publisher. Supports coalesced
          # reactive probes after dispatch-triggered instance_unavailable
          # transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Logging::Helper
            include EvidenceBuilding
            include ValueEvidenceBuilding
            include OfferingAssembly
            include HealthProbing
            include OfferingComparison
            include WeightPublication
            include TickCycle
            include InstanceConfig
            include HealthDisplay
            include HttpConnections

            # Mirrors the registered lex-llm default
            # (discovery.interval_seconds); used only when the settings tree
            # has no discovery section. time must never return nil — a
            # TimerTask with a nil interval fires exactly once and stops.
            DEFAULT_DISCOVERY_INTERVAL_SECONDS = 300

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              interval = settings.dig(:discovery, :interval_seconds)
              interval.is_a?(Integer) && interval.positive? ? interval : DEFAULT_DISCOVERY_INTERVAL_SECONDS
            end

            def manual
              tick_refresh
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
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                provider_family: :mlx,
                compatibility_adapter: Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                  provider_family: :mlx
                )
              )
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = name.to_s
              physical_id = derive_physical_id(instance_cfg: instance_cfg)
              instance_key = build_instance_key(instance_id: instance_id, physical_id: physical_id)
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              callable = Legion::Extensions::Llm::Mlx::Actor::MlxCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = build_probe_coordinator(instance_id: instance_id, instance_key: instance_key)
              publisher_token = publisher.claim_instance(
                instance_id: instance_id, physical_id: physical_id, callable: callable,
                probe_request_handle: probe_coordinator
              )
              run_activation(
                instance_id: instance_id, publisher_token: publisher_token,
                offerings: offerings,
                instance_desc: { name: name, instance_id: instance_id, physical_id: physical_id,
                                 instance_key: instance_key, instance_cfg: instance_cfg,
                                 callable: callable, probe_coordinator: probe_coordinator }
              )
            end

            def run_activation(instance_id:, publisher_token:, offerings:, instance_desc:)
              instance_cfg = instance_desc[:instance_cfg]
              state = build_instance_state(
                **instance_desc, publisher_token: publisher_token, offerings: offerings
              )
              Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
                states: @instance_states,
                state_key: instance_id,
                state: state,
                mutex: state_mutex
              )
              probe_token = publisher.readiness_probe_started(instance_id: instance_id,
                                                              publisher_token: publisher_token)
              readiness = check_health(instance_cfg: instance_cfg)
              committed = commit_readiness(
                instance_id: instance_id, probe_token: probe_token,
                readiness: readiness, state: state
              )
              write_instance_health(config_name: instance_desc[:name], state: state) if committed
            end

            def remove_all_instances
              states = state_mutex.synchronize do
                return if @instance_states.nil?

                @instance_states.to_a
              end
              states.each do |instance_id, state|
                remove_instance_state(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'mlx.actor.remove_instance',
                                    instance_id: instance_id)
              end
              state_mutex.synchronize do
                @instance_states.clear
                dormant_weight_tracker.clear!
              end
            end
          end

          # Callable wrapper for an MLX provider instance. It is the
          # exact-execution dispatch target: it implements the fleet dispatch
          # operations (chat, stream_chat, embed, count_tokens) by delegating
          # to a per-instance Mlx::Provider built from the instance config,
          # plus the `disconnect` and `normalize_dispatch_error(error:)`
          # contracts required by Inventory::CallableHandle and
          # Routing::ProviderOutcome. Provider and Faraday errors are NOT
          # rescued here so the coordinator's normalize_dispatch_error can
          # classify them.
          class MlxCallable
            # Keys the base Provider exposes as named kwargs for the
            # completion operations. Anything else the fleet passes is folded
            # into the payload `params` hash.
            COMPLETION_NAMED_KEYS = %i[tools temperature schema thinking tool_prefs headers].freeze
            EMBED_NAMED_KEYS = %i[dimensions headers].freeze

            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
              @inference_calls = 0
            end

            def call_count
              @inference_calls
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[mlx][callable] disconnected' }
            end

            # ── Fleet dispatch operations ───────────────────────────────────

            def chat(messages:, model:, **rest)
              record_inference
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages: messages, model: model_info(model), params: params, **named)
            end

            def stream_chat(messages:, model:, **rest, &)
              record_inference
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages: messages, model: model_info(model), params: params, **named, &)
            end

            def embed(text:, model:, **rest)
              record_inference
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model_info(model), params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              record_inference
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
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

            def record_inference
              @inference_calls += 1
            end

            def provider
              @provider ||= Legion::Extensions::Llm::Mlx::Provider.new(@instance_cfg)
            end

            # The fleet passes the model as a bare string; the base Provider's
            # payload renderer needs a Model::Info (model.id). Wrap strings
            # only — pass through anything already carrying model identity.
            def model_info(model)
              return model if model.respond_to?(:id)

              Legion::Extensions::Llm::Model::Info.new(
                id: model.to_s, provider: Legion::Extensions::Llm::Mlx::PROVIDER_FAMILY
              )
            end

            # Split the fleet's **rest into the base Provider's named kwargs
            # and a payload params hash (any passed :params merged with
            # unknown keys).
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
            end

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
