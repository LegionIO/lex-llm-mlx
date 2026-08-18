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

    it 'claims a named instance alongside the synthetic default, never the phantom' do
      settings_tree[:instances] = { default: synthetic_default, studio: { endpoint: "http://#{studio_id}" } }
      make_healthy!

      actor.manual

      expect(instance_ids).to eq(['studio'])
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
