# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/mlx/actors/discovery_refresh'

# Lifecycle coverage for the SSOT discovery actor: claim/activate,
# initial-failure recovery (D4), tick reconcile, display health writes
# (D14), and cadence resolution (D9). The HTTP boundary of the readiness
# probe and model fetch is stubbed on the actor instance so the registry
# state machine runs offline.
RSpec.describe Legion::Extensions::Llm::Mlx::Actor::DiscoveryRefresh do
  # let (not subject) so the probe-boundary stubs below are not
  # flagged as stubbing the object under test.
  let(:actor) { described_class.new }

  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_tree) { Legion::Settings.loader.settings[:extensions][:llm][:mlx] }

  # Plain methods (not lets) to stay under RSpec/MultipleMemoizedHelpers.

  # Physical endpoints (host:port) — the SECONDARY physical id. Identity
  # is the operator's config name (:studio / :other below).
  def studio_id = '127.0.0.1:1'

  def other_id = '127.0.0.1:2'

  def studio_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :mlx, instance_id: 'studio', physical_id: studio_id
    )
  end

  def other_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :mlx, instance_id: 'other', physical_id: other_id
    )
  end

  def readiness(ready:, reason:)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: ready, reason: reason)
  end

  def healthy
    readiness(ready: true, reason: 'MLX /health returned 200')
  end

  def unhealthy
    readiness(ready: false, reason: 'MLX /health connection failed')
  end

  # Boundary stubs: the actor builds its own Faraday connections per
  # probe/fetch, so the probe + model-fetch boundary is stubbed on the
  # actor instance (there is no injectable seam at the connection level).
  def stub_probe_boundaries
    allow(actor).to receive_messages(
      fetch_models: [{ id: 'test-model', max_model_len: 4096 }],
      check_health: unhealthy
    )
  end

  def make_healthy!
    allow(actor).to receive(:check_health).and_return(healthy)
  end

  def expect_publication(instance_key:, state:)
    expect(registry.snapshot.publication_status(instance_key: instance_key).state).to eq(state)
  end

  def expect_instance_availability(instance_key:, state:)
    expect(registry.snapshot.instance(instance_key: instance_key).availability.state).to eq(state)
  end

  def studio_health
    settings_tree[:instances][:studio][:health]
  end

  def expect_display_health(available:, circuit_state:, adjustment:, outcome:, reason: nil)
    health = studio_health
    expect(health[:available]).to be(available)
    expect(health[:circuit_state]).to eq(circuit_state)
    expect(health[:adjustment]).to eq(adjustment)
    expect_health_metadata(health: health, last_probe_outcome: outcome, reason: reason)
  end

  def expect_health_metadata(health:, last_probe_outcome:, reason:)
    expected = { denied: false, last_probe_outcome: last_probe_outcome,
                 source: :provider_probe, observed_at: be_a(String) }
    expected[:reason] = reason if reason
    expect(health.slice(*expected.keys)).to match(expected)
  end

  def expect_display_capabilities(*capabilities)
    expect(settings_tree[:instances][:studio][:capabilities]).to include(*capabilities)
  end

  before do
    registry.reset!
    settings_tree.replace(instances: { studio: { endpoint: "http://#{studio_id}" } })
    stub_probe_boundaries
  end

  after { settings_tree.replace({}) }

  describe '#manual' do
    it 'claims the configured instance and stays initializing after an initial readiness failure' do
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: studio_key).state).to eq(:initializing)
      expect(registry.snapshot.instance(instance_key: studio_key)).to be_nil
    end

    it 'writes the display health hash into settings after the initial readiness commit' do
      actor.manual

      expect_display_health(available: false, circuit_state: :open, adjustment: -50, outcome: :failure,
                            reason: 'MLX /health connection failed')
    end

    it 're-activates an initializing instance on the first healthy tick' do
      actor.manual
      make_healthy!
      actor.manual

      expect_instance_availability(instance_key: studio_key, state: :available)
      expect_publication(instance_key: studio_key, state: :complete)
      expect_display_health(available: true, circuit_state: :closed, adjustment: 0, outcome: :success)
      expect_display_capabilities(:completion, :streaming)
    end

    it 'stays initializing while the instance remains unhealthy' do
      actor.manual
      actor.manual

      expect_publication(instance_key: studio_key, state: :initializing)
      expect(registry.snapshot.instance(instance_key: studio_key)).to be_nil
    end

    it 'publishes offerings for a healthy instance at boot' do
      make_healthy!
      actor.manual

      offerings = registry.snapshot.offerings_for(instance_key: studio_key)
      expect(offerings.map(&:model)).to eq(['test-model'])
      expect(offerings.first.operation_evidence[:chat].status).to eq(:supported)
      expect(offerings.first.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'removes instances that are no longer configured (tick reconcile)' do
      actor.manual
      expect_publication(instance_key: studio_key, state: :initializing)

      settings_tree[:instances].replace(other: { endpoint: "http://#{other_id}" })
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: studio_key)).to be_nil
      expect_publication(instance_key: other_key, state: :initializing)
    end

    it 'clears registry state and settings health on shutdown' do
      make_healthy!
      actor.manual
      expect(registry.snapshot.instance(instance_key: studio_key)).not_to be_nil

      actor.shutdown

      expect(registry.snapshot.instance(instance_key: studio_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: studio_key)).to be_nil
      expect(settings_tree[:instances][:studio][:health]).to be_nil
    end
  end

  # D3: only operator-configured instances are registered — the synthetic
  # instances.default template is an unconfigured phantom while unmodified
  # (the provider-layer skip keeps it out of the claim path before
  # InstanceKey ever sees the reserved name).
  describe 'unconfigured phantom handling (D3)' do
    let(:synthetic_default) { Legion::Extensions::Llm::Mlx.default_settings.dig(:instances, :default) }

    def instance_ids
      registry.snapshot.each_instance.map { |record| record.instance_key.instance_id }
    end

    it 'registers nothing when only the synthetic default is present' do
      settings_tree[:instances] = { default: synthetic_default }

      actor.manual

      expect(instance_ids).to be_empty
      # The derived host:port is the SECONDARY physical id, never the
      # identity — nothing is published under it either.
      expect(registry.snapshot.publication_status(
               instance_key: Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                 provider_family: :mlx, instance_id: 'localhost:8000', physical_id: 'localhost:8000'
               )
             )).to be_nil
    end

    it 'claims a named instance alongside the default instance' do
      settings_tree[:instances] = { default: synthetic_default, studio: { endpoint: "http://#{studio_id}" } }
      make_healthy!

      actor.manual

      expect(instance_ids).to contain_exactly('default', 'studio')
    end

    it 'keeps the discovery pass alive when the foundation rejects the configured default claim' do
      # The provider layer passes a configured (non-template)
      # instances.default to the claim path (v2 parity). Whether the
      # foundation accepts the name is a lex-llm InstanceKey contract,
      # not a provider-layer decision: under the current lex-llm floor
      # the claim raises, the actor logs it, and the rest of the pass
      # still runs — a claim failure for one instance must not poison
      # the others.
      settings_tree[:instances] = {
        default: synthetic_default.merge(endpoint: 'http://127.0.0.1:11500'),
        studio: { endpoint: "http://#{studio_id}" }
      }
      make_healthy!

      actor.manual

      expect(instance_ids).to include('studio')
    end
  end

  describe '#time' do
    it 'honors the registered discovery.interval_seconds' do
      settings_tree[:discovery] = { enabled: true, interval_seconds: 42 }
      expect(actor.time).to eq(42)
    end

    it 'never returns nil and falls back to the registered default' do
      settings_tree.replace({})
      expect(actor.time).to eq(described_class::DEFAULT_DISCOVERY_INTERVAL_SECONDS)
      expect(actor.time).to be_a(Integer).and be > 0
    end
  end

  describe 'write-time weight publication' do
    def configure_weights(provider: 100, instance: 100, models: { 'test-model' => 100 }, tier: 100)
      model_settings = models.transform_values { |weight| { weight: weight } }
      settings_tree.replace(
        weight: provider,
        models: model_settings,
        instances: {
          studio: {
            endpoint: "http://#{studio_id}", tier: :local,
            weight: instance
          }
        }
      )
      Legion::Settings.loader.settings[:llm] = {
        routing: { tier_weights: { local: tier } }
      }
    end

    def build_weighted_draft(model_id: 'test-model')
      actor.send(
        :build_offering_draft,
        model_id: model_id,
        model_data: { id: model_id, max_model_len: 4096 },
        instance_cfg: { endpoint: "http://#{studio_id}", tier: :local },
        instance_key: studio_key
      )
    end

    def writer_state(draft:, published: true)
      {
        name: :studio,
        instance_id: 'studio',
        physical_id: studio_id,
        instance_key: studio_key,
        instance_cfg: { endpoint: "http://#{studio_id}", tier: :local },
        publisher_token: Object.new,
        offerings: [draft].freeze,
        sequence: 0,
        published: published
      }
    end

    def replace_calls_for(publisher)
      calls = []
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |method, **kwargs|
        calls << kwargs
        method.call(**kwargs)
      end
      calls
    end

    around do |example|
      root = Legion::Settings.loader.settings
      original_llm = root[:llm]
      example.run
    ensure
      root[:llm] = original_llm
    end

    before { make_healthy! }

    it 'constructs each draft with the exact four weight inputs and product' do
      configure_weights(provider: 120, instance: 110, models: { 'test-model' => 130 }, tier: 140)

      draft = build_weighted_draft

      expect(draft.weight_inputs).to eq(tier: 140, provider: 120, instance: 110, model_or_offering: 130)
      expect(draft.base_weight).to eq(240_240_000)
      expect(draft.base_weight).to eq(draft.weight_inputs.values.reduce(1, :*))
    end

    it 'publishes one frozen replacement for a weight-only change on the next ordinary pass' do
      configure_weights
      publisher = actor.send(:publisher)
      replacements = replace_calls_for(publisher)
      fetches = 0
      probes = 0
      display_writes = 0
      allow(actor).to receive(:fetch_models) do
        fetches += 1
        [{ id: 'test-model', max_model_len: 4096 }]
      end
      allow(actor).to receive(:check_health) do
        probes += 1
        healthy
      end
      allow(actor).to receive(:write_instance_health).and_wrap_original do |method, **kwargs|
        display_writes += 1
        method.call(**kwargs)
      end

      actor.manual
      settings_tree[:weight] = 125
      actor.manual

      expect(replacements.length).to eq(1)
      expect(replacements.first[:offerings]).to be_frozen
      expect(replacements.first[:offerings].first.weight_inputs[:provider]).to eq(125)
      expect(fetches).to eq(2)
      expect(probes).to eq(2)
      expect(display_writes).to eq(2)
    end

    it 'publishes nothing when a settings change leaves the weight pair unchanged' do
      configure_weights
      publisher = actor.send(:publisher)
      replacements = replace_calls_for(publisher)
      actor.manual
      state = actor.instance_variable_get(:@instance_states).fetch('studio')
      sequence = state.fetch(:sequence)

      settings_tree[:unrelated_setting] = 'changed'
      actor.manual

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(sequence)
    end

    it 'treats only evidence observation timestamps as volatile' do
      configure_weights
      first = build_weighted_draft
      second = build_weighted_draft

      expect(first).not_to eq(second)
      expect(actor.send(:offerings_equivalent?, [first], [second])).to be(true)
    end

    it 'does not replace an equivalent catalog returned in a different order' do
      configure_weights
      catalog = [
        { id: 'model-a', max_model_len: 4096 },
        { id: 'model-b', max_model_len: 8192 }
      ]
      allow(actor).to receive(:fetch_models).and_return(catalog, catalog.reverse)
      publisher = actor.send(:publisher)
      replacements = replace_calls_for(publisher)

      actor.manual
      state = actor.instance_variable_get(:@instance_states).fetch('studio')
      actor.manual

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(0)
    end

    it 'replaces once when an otherwise duplicate offering is added' do
      configure_weights
      catalog = [
        { id: 'model-a', max_model_len: 4096 },
        { id: 'model-b', max_model_len: 8192 }
      ]
      allow(actor).to receive(:fetch_models).and_return(catalog, catalog + [catalog.first])
      publisher = actor.send(:publisher)
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) { |**kwargs| replacements << kwargs }

      actor.manual
      state = actor.instance_variable_get(:@instance_states).fetch('studio')
      actor.manual

      expect(replacements.length).to eq(1)
      expect(replacements.first.fetch(:offerings).length).to eq(3)
      expect(state.fetch(:sequence)).to eq(1)
    end

    it 'publishes when contract evidence content changes' do
      configure_weights
      publisher = actor.send(:publisher)
      replacements = replace_calls_for(publisher)
      actor.manual
      allow(actor).to receive(:fetch_models).and_return([{ id: 'test-model', max_model_len: 8192 }])

      actor.manual

      expect(replacements.length).to eq(1)
      evidence = replacements.first[:offerings].first.context_evidence
      expect(evidence.value).to eq(8192)
    end

    it 'preserves an explicit zero and rejects false instead of defaulting it' do
      configure_weights(provider: 0)
      expect(build_weighted_draft.weight_inputs[:provider]).to eq(0)

      settings_tree[:weight] = false
      expect { build_weighted_draft }.to raise_error(ArgumentError, /Integer >= 0/)
    end

    it 'leaves no claimed scope for malformed weights and cleanly retries after correction' do
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:claim_instance).and_call_original
      configure_weights(provider: false)

      actor.manual

      snapshot = registry.snapshot
      expect(publisher).not_to have_received(:claim_instance)
      expect(snapshot.each_publication_status.to_a).to be_empty
      expect(snapshot.each_instance.to_a).to be_empty
      expect(snapshot.each_offering.to_a).to be_empty
      expect(actor.instance_variable_get(:@instance_states)).to be_empty

      settings_tree[:weight] = 100
      actor.manual
      actor.manual

      expect(publisher).to have_received(:claim_instance).once
      expect(registry.snapshot.publication_status(instance_key: studio_key).state).to eq(:complete)
      expect(registry.snapshot.each_instance.to_a.size).to eq(1)
      expect(registry.snapshot.offerings_for(instance_key: studio_key).size).to eq(1)
      expect(actor.instance_variable_get(:@instance_states).fetch('studio')[:published]).to be(true)
    end

    it 'logs the complete dormant cycle once per disappearance on ordinary passes' do
      ghost_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: 'ghost', physical_id: 'ghost.local:8000'
      )
      configure_weights
      settings_tree[:instances] = {
        ghost: { endpoint: 'http://ghost.local:8000', tier: :local, weight: 123 }
      }
      logger = instance_double(Logger, info: nil)
      allow(actor).to receive(:log).and_return(logger)
      allow(actor).to receive(:claim_and_activate_instance)
      allow(actor).to receive(:refresh_instance)

      actor.manual
      actor.manual
      draft = build_weighted_draft
      actor.instance_variable_get(:@instance_states)['ghost'] = {
        published: true, instance_key: ghost_key, offerings: [draft]
      }
      actor.manual
      actor.instance_variable_get(:@instance_states).delete('ghost')
      actor.manual

      text = '[llm][mlx] action=dormant_weight ' \
             'weight_key=[:mlx, :instance, "ghost"] no_lane_published=true'
      expect(logger).to have_received(:info).with(text).twice
    end

    it 'keeps sequence stable through ten unchanged ordinary passes' do
      configure_weights
      publisher = actor.send(:publisher)
      replacements = replace_calls_for(publisher)
      actor.manual
      state = actor.instance_variable_get(:@instance_states).fetch('studio')

      10.times { actor.manual }

      expect(replacements).to be_empty
      expect(state.fetch(:sequence)).to eq(0)
    end

    it 'has no Settings lifecycle path and clears only repository-local tracking on shutdown' do
      source = File.read(described_class.instance_method(:manual).source_location.first)
      lifecycle_calls = /Legion::Settings\.(?:on_reload|off_reload|reload!|reset!)/
      expect(source).not_to match(lifecycle_calls)

      configure_weights
      settings_tree[:instances] = {
        ghost: { endpoint: 'http://ghost.local:8000', tier: :local, weight: 123 }
      }
      allow(actor).to receive(:claim_and_activate_instance)
      actor.manual
      tracker = actor.instance_variable_get(:@dormant_weight_tracker)
      actor.shutdown

      key = [:mlx, :instance, 'ghost']
      expect(tracker.observe(configured_keys: [key], published_keys: [])).to eq([key])
    end

    it 'serializes interleaved ordinary passes with monotonic unique publications' do
      configure_weights(models: { 'initial' => 100, 'model-a' => 101, 'model-b' => 102 })
      initial = build_weighted_draft(model_id: 'initial')
      state = writer_state(draft: initial)
      actor.instance_variable_set(:@instance_states, 'studio' => state)
      arrived = Queue.new
      release = Queue.new
      publications = []
      publication_mutex = Mutex.new
      publisher = instance_double(Legion::Extensions::Llm::Inventory::Publisher)
      allow(publisher).to receive(:replace_instance_snapshot) do |**kwargs|
        publication_mutex.synchronize { publications << kwargs }
      end
      allow(actor).to receive(:publisher).and_return(publisher)
      allow(actor).to receive(:discover_offerings_for_instance) do
        arrived << true
        release.pop
        [build_weighted_draft(model_id: Thread.current.fetch(:model_id))]
      end

      threads = %w[model-a model-b].map do |model_id|
        Thread.new do
          Thread.current[:model_id] = model_id
          actor.send(:replace_offerings_if_changed, instance_id: 'studio', state: state)
        end
      end
      2.times { arrived.pop }
      2.times { release << true }
      threads.each(&:value)

      expect(publications.map { |entry| entry[:sequence] }).to eq([1, 2])
      expect(publications.map { |entry| entry[:offerings].first.base_weight }.uniq.length).to eq(2)
      expect(state.fetch(:offerings)).to eq(publications.last.fetch(:offerings))
      expect(state.fetch(:sequence)).to eq(2)
    end

    it 'leaves the cache unchanged on replace failure and retries on the next pass' do
      configure_weights(models: { 'initial' => 100, 'replacement' => 175 })
      original = build_weighted_draft(model_id: 'initial')
      replacement = build_weighted_draft(model_id: 'replacement')
      state = writer_state(draft: original)
      publisher = instance_double(Legion::Extensions::Llm::Inventory::Publisher)
      allow(actor).to receive_messages(publisher: publisher, discover_offerings_for_instance: [replacement])
      allow(publisher).to receive(:replace_instance_snapshot).and_raise('publish failed')

      expect do
        actor.send(:replace_offerings_if_changed, instance_id: 'studio', state: state)
      end.to raise_error(RuntimeError, 'publish failed')
      expect(state.values_at(:sequence, :offerings)).to eq([0, [original].freeze])

      allow(publisher).to receive(:replace_instance_snapshot)
      actor.send(:replace_offerings_if_changed, instance_id: 'studio', state: state)
      expect(state.fetch(:sequence)).to eq(1)
      expect(state.fetch(:offerings).first.model).to eq('replacement')
    end

    it 'rebuilds with current settings after draft construction but before initial activation' do
      configure_weights(models: { 'test-model' => 101 })
      allow(actor).to receive(:fetch_models).and_return([{ id: 'test-model', max_model_len: 4096 }])
      entered = Queue.new
      release = Queue.new
      allow(actor).to receive(:check_health) do
        entered << true
        release.pop
        healthy
      end
      actor.instance_variable_set(:@instance_states, {})
      instance_cfg = Legion::Extensions::Llm::Mlx.configured_instances.fetch(:studio)

      activation = Thread.new do
        actor.send(:claim_and_activate_instance, name: :studio, instance_cfg: instance_cfg)
      end
      entered.pop
      settings_tree[:models]['test-model'][:weight] = 175
      release << true
      activation.value

      offering = registry.snapshot.offerings_for(instance_key: studio_key).first
      state = actor.instance_variable_get(:@instance_states).fetch('studio')
      expect(offering.weight_inputs[:model_or_offering]).to eq(175)
      expect(state.fetch(:offerings).first.weight_inputs[:model_or_offering]).to eq(175)
    end

    it 'updates an unpublished cache without replace or activate and keeps it dormant' do
      configure_weights
      make_unhealthy = readiness(ready: false, reason: 'still unavailable')
      logger = Logger.new(File::NULL)
      allow(logger).to receive(:info).and_call_original
      allow(actor).to receive_messages(check_health: make_unhealthy, log: logger)
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      actor.manual

      settings_tree[:weight] = 175
      actor.manual
      state = actor.instance_variable_get(:@instance_states).fetch('studio')

      expect(state.fetch(:published)).to be(false)
      expect(state.fetch(:offerings).first.weight_inputs[:provider]).to eq(175)
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(logger).to have_received(:info).with(
        '[llm][mlx] action=dormant_weight ' \
        'weight_key=[:mlx, :provider] no_lane_published=true'
      ).once
    end

    it 'does not resurrect a tracked state removed while readiness is in flight' do
      configure_weights
      allow(actor).to receive(:fetch_models).and_return([{ id: 'test-model', max_model_len: 4096 }])
      entered = Queue.new
      release = Queue.new
      allow(actor).to receive(:check_health) do
        entered << true
        release.pop
        healthy
      end
      actor.instance_variable_set(:@instance_states, {})
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      allow(actor).to receive(:write_instance_health).and_call_original
      instance_cfg = Legion::Extensions::Llm::Mlx.configured_instances.fetch(:studio)

      activation = Thread.new do
        actor.send(:claim_and_activate_instance, name: :studio, instance_cfg: instance_cfg)
      end
      entered.pop
      state = actor.instance_variable_get(:@instance_states).fetch('studio')
      actor.send(:remove_instance_state, instance_id: 'studio', state: state)
      release << true
      activation.value

      expect(actor.instance_variable_get(:@instance_states)).not_to have_key('studio')
      expect(registry.snapshot.publication_status(instance_key: studio_key)).to be_nil
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(actor).not_to have_received(:write_instance_health)
    end

    it 'leaves unpublished state unchanged when activation raises and permits retry' do
      configure_weights
      draft = build_weighted_draft
      state = writer_state(draft: draft, published: false)
      actor.instance_variable_set(:@instance_states, 'studio' => state)
      publisher = instance_double(Legion::Extensions::Llm::Inventory::Publisher)
      allow(actor).to receive(:publisher).and_return(publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_raise('activation failed')

      expect do
        actor.send(
          :commit_readiness, instance_id: 'studio', probe_token: Object.new,
                             readiness: healthy, state: state
        )
      end.to raise_error(RuntimeError, 'activation failed')
      expect(state.values_at(:sequence, :offerings, :published)).to eq([0, [draft].freeze, false])

      allow(publisher).to receive(:activate_instance_snapshot)
      result = actor.send(
        :commit_readiness, instance_id: 'studio', probe_token: Object.new,
                           readiness: healthy, state: state
      )
      expect(result).to be(true)
      expect(state.fetch(:published)).to be(true)
    end
  end

  # D16: only network/parse errors may yield zero offerings. Programming
  # errors must fail loud — converting them to [] would publish an
  # activated instance with zero offerings (invisible to routing).
  describe 'offering discovery rescue discipline' do
    # The group's outer before stubs fetch_models with a canned list; the
    # boundary tests below need the REAL fetch_models against a stubbed
    # connection, so re-enable the original implementation here.
    before do
      allow(actor).to receive(:fetch_models).and_call_original
    end

    it 'fails loud on a programming error instead of publishing zero offerings' do
      allow(actor).to receive(:fetch_models).and_return([{ id: 'test-model' }])
      allow(actor).to receive(:fetch_models).and_return([{ id: 'test-model' }])
      allow(actor).to receive(:build_offering_draft)
        .and_raise(NameError, 'undefined constant Bogus::Thing')

      expect do
        actor.send(:discover_offerings_for_instance, instance_cfg: {}, instance_key: studio_key)
      end.to raise_error(NameError)
    end

    it 'yields no offerings for a network failure' do
      # Faraday::ConnectionFailed is raised by the adapter before any
      # response exists; simulate the boundary directly.
      allow(actor).to receive(:build_api_connection)
        .and_raise(Faraday::ConnectionFailed, 'Connection refused')

      expect(actor.send(:fetch_models, instance_cfg: {})).to eq([])
    end

    it 'yields no offerings for an unparseable model-list body' do
      conn = instance_double(Faraday::Connection,
                             get: Faraday::Response.new(status: 502, body: '<html>bad gateway</html>'))
      allow(actor).to receive(:build_api_connection).and_return(conn)

      expect(actor.send(:fetch_models, instance_cfg: {})).to eq([])
    end

    it 'yields no offerings for a well-formed but non-array :data field' do
      conn = instance_double(Faraday::Connection,
                             get: Faraday::Response.new(status: 200, body: '{"data": {}}'))
      allow(actor).to receive(:build_api_connection).and_return(conn)

      expect(actor.send(:fetch_models, instance_cfg: {})).to eq([])
    end
  end
end
