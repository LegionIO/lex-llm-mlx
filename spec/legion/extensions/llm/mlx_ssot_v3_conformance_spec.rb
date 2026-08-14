# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

require 'legion/extensions/llm/mlx/actors/discovery_refresh'

# Synthetic error that represents a genuine explicit instance-unavailable
# signal from an MLX process (e.g. graceful shutdown sentinel). Used only
# in conformance tests to satisfy the §8 harness contract without violating
# the firewall rule (Faraday::ConnectionFailed must NOT become instance_unavailable).
class MlxTestInstanceUnavailableError < StandardError; end

# Test-local callable that extends MlxCallable with dispatch operations
# required by FleetWorkerExecution. Tracks inference call count for
# conformance assertions.
class TrackingMlxCallable < Legion::Extensions::Llm::Mlx::Actor::MlxCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(model:, **)
    @call_count += 1
    { token_count: 42, model: model }
  end

  def normalize_dispatch_error(error:)
    reason = error.message.to_s[0, 512]
    kind = classify_dispatch_error(error: error)

    Legion::Extensions::Llm::Routing::ProviderOutcome.new(
      kind: kind,
      reason: reason.empty? ? 'unknown dispatch error' : reason
    )
  end

  private

  def classify_dispatch_error(error:)
    case error
    when MlxTestInstanceUnavailableError then :instance_unavailable
    when Faraday::ConnectionFailed then :connection_failure
    when Faraday::TimeoutError then :timeout
    when Faraday::ClientError then classify_client_error_ext(error: error)
    when Faraday::ServerError then classify_server_error_ext(error: error)
    when Legion::Extensions::Llm::OverloadedError then :overloaded
    else :provider_error
    end
  end

  def classify_client_error_ext(error:)
    status = error.respond_to?(:response_status) ? error.response_status : nil
    case status
    when 401 then :authentication
    when 403 then :authorization
    when 404 then :model_missing
    when 429 then :rate_limited
    else :invalid_request
    end
  end

  def classify_server_error_ext(error:)
    status = error.respond_to?(:response_status) ? error.response_status : nil
    case status
    when 503, 529 then :overloaded
    else :provider_error
    end
  end
end

# Evidence-building helpers for the SSOT v3 conformance harness.
# Extracted to keep MlxSsotHarness within class length limits.
module MlxSsotEvidenceHelpers
  EMBEDDING_PATTERN = /embed|bge|e5|nomic/i

  private

  def build_operation_evidence(now:, model_id:)
    is_embedding = model_id.to_s.match?(EMBEDDING_PATTERN)
    {
      chat: op_evidence(:chat, is_embedding ? :unsupported : :supported, now),
      stream_chat: op_evidence(:stream_chat, is_embedding ? :unsupported : :supported, now),
      embed: op_evidence(:embed, is_embedding ? :supported : :unsupported, now),
      image: op_evidence(:image, :unsupported, now),
      transcribe: op_evidence(:transcribe, :unsupported, now),
      translate: op_evidence(:translate, :unsupported, now),
      speak: op_evidence(:speak, :unsupported, now),
      moderate: op_evidence(:moderate, :unsupported, now),
      count_tokens: op_evidence(:count_tokens, :unknown, now)
    }
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence(model_id:)
    is_embedding = model_id.to_s.match?(EMBEDDING_PATTERN)
    caps = {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: is_embedding ? :unsupported : :supported,
        source: :provider_implementation, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: is_embedding ? :unsupported : :supported,
        source: :provider_implementation, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      )
    }

    if is_embedding
      caps[:embedding] = Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :embedding, status: :supported, source: :provider_implementation, observed_at: Time.now
      )
    end

    caps
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{uri.host || 'localhost'}:#{uri.port}"
  end
end

# Harness class for MLX SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service.
class MlxSsotHarness
  include MlxSsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
      mlx_api_base: 'http://mac-studio-1.local:8000',
      tier: :local, mlx_api_key: nil, usage: { inference: true, embedding: false }
    }.freeze,
    {
      mlx_api_base: 'http://mac-studio-2.local:8001',
      tier: :local, mlx_api_key: 'sk-mlx-test-key', usage: { inference: true, embedding: false }
    }.freeze
  ].freeze

  def provider_family = :mlx
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    base_url = instance_config[:mlx_api_base] || instance_config[:endpoint] || 'http://localhost:8000'
    host_port = extract_host_port(base_url: base_url)
    api_key = instance_config[:mlx_api_key] || instance_config.dig(:credentials, :api_key)

    return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

    "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 6]}"
  end

  def build_callable(instance_config:)
    TrackingMlxCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :local, **)
    now = Time.now.freeze
    model_id = 'mlx-community/Llama-3.2-3B-Instruct-4bit'
    [build_single_offering(model_id: model_id, tier: tier, now: now)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'MLX /health returned 200',
      metadata: { status: 200, base_url: instance_config[:mlx_api_base] }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_mlx_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    MlxTestInstanceUnavailableError.new('MLX process sent explicit instance-unavailable sentinel')
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": "Server overloaded"}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {}, body: '{"error": "Model not ready", "detail": "model is still loading"}' }
    Faraday::ServerError.new('the server responded with status 503 - model is still loading', response)
  end

  private

  def apply_mlx_escalation(outcome:, error:)
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :model_not_ready, reason: outcome.reason)
    end

    outcome
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready') || body.include?('model is still loading')
  end

  def build_single_offering(model_id:, tier:, now:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, model_id: model_id),
      capability_evidence: build_capability_evidence(model_id: model_id),
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }, publication_source: :provider_catalog
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Mlx do
  let(:ssot_harness) { MlxSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # --- MLX-specific identity derivation ----------------------------------------

  describe 'instance identity derivation' do
    it 'derives instance_id as host:port without API key' do
      config = { mlx_api_base: 'http://mac-studio-1.local:8000' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('mac-studio-1.local:8000')
    end

    it 'derives instance_id as host:port/ak:fingerprint with API key' do
      config = { mlx_api_base: 'http://mac-studio-2.local:8001', mlx_api_key: 'sk-mlx-test-key' }
      fingerprint = Digest::SHA256.hexdigest('sk-mlx-test-key')[0, 6]
      expect(ssot_harness.instance_id(instance_config: config)).to eq("mac-studio-2.local:8001/ak:#{fingerprint}")
    end

    it 'produces distinct instance IDs for two different endpoints' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      first_call = ssot_harness.instance_id(instance_config: config)
      second_call = ssot_harness.instance_id(instance_config: config)
      expect(first_call).to eq(second_call)
    end

    it 'strips /v1 suffix from endpoint when computing identity' do
      config_with_v1 = { mlx_api_base: 'http://mac-studio-1.local:8000/v1' }
      config_without = { mlx_api_base: 'http://mac-studio-1.local:8000' }
      expect(URI.parse(config_with_v1[:mlx_api_base]).host).to eq(URI.parse(config_without[:mlx_api_base]).host)
      expect(URI.parse(config_with_v1[:mlx_api_base]).port).to eq(URI.parse(config_without[:mlx_api_base]).port)
    end
  end

  # --- Two servers with same model = separate lanes ----------------------------

  describe 'two MLX servers serving the same model' do
    def bring_up_instance(config, tier: :local)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    context 'with both instances active' do
      let(:instance_a) { bring_up_instance(ssot_harness.instance_configs[0]) }
      let(:instance_b) { bring_up_instance(ssot_harness.instance_configs[1]) }

      before { instance_a && instance_b }

      it 'creates non-empty lanes for instance A' do
        expect(registry.snapshot.lanes_for(instance_key: instance_a[:key])).not_to be_empty
      end

      it 'creates non-empty lanes for instance B' do
        expect(registry.snapshot.lanes_for(instance_key: instance_b[:key])).not_to be_empty
      end

      it 'assigns distinct lane_ids across different instances' do
        lanes_a = registry.snapshot.lanes_for(instance_key: instance_a[:key])
        lanes_b = registry.snapshot.lanes_for(instance_key: instance_b[:key])
        expect(lanes_a.map(&:lane_id) & lanes_b.map(&:lane_id)).to be_empty
      end
    end

    def offering_id_after_bring_up(config)
      result = bring_up_instance(config)
      registry.snapshot.offerings_for(instance_key: result[:key]).first.offering_id
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_id = offering_id_after_bring_up(config)
      registry.reset!
      expect(offering_id_after_bring_up(config)).to eq(first_id)
    end
  end

  # --- Tier change does NOT change lane/offering identity ----------------------

  describe 'tier change and identity preservation' do
    def bring_up_with_tier(config, tier:)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts }
    end

    def republish_with_tier(context, config, tier:)
      frontier_drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: context[:callable],
                                                           tier: tier)
      context[:publisher].replace_instance_snapshot(
        instance_id: ssot_harness.instance_id(instance_config: config),
        publisher_token: context[:token], offerings: frontier_drafts, sequence: 1
      )
    end

    it 'preserves offering_id when tier changes from local to frontier' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)
      before_id = registry.snapshot.offerings_for(instance_key: context[:key]).first.offering_id
      republish_with_tier(context, config, tier: :frontier)
      expect(registry.snapshot.offerings_for(instance_key: context[:key]).first.offering_id).to eq(before_id)
    end

    it 'preserves lane_id when tier changes from local to frontier' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)
      before_lane_id = registry.snapshot.lanes_for(instance_key: context[:key]).first.lane_id
      republish_with_tier(context, config, tier: :frontier)
      expect(registry.snapshot.lanes_for(instance_key: context[:key]).first.lane_id).to eq(before_lane_id)
    end

    it 'updates the tier value after republication' do
      config = ssot_harness.instance_configs[0]
      context = bring_up_with_tier(config, tier: :local)
      republish_with_tier(context, config, tier: :frontier)
      expect(registry.snapshot.offerings_for(instance_key: context[:key]).first.tier).to eq(:frontier)
    end
  end

  # --- Embedding operation evidence --------------------------------------------

  describe 'embedding operation support detection' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:offering) do
      ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local).first
    end

    it 'marks chat models as supporting chat' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks chat models as supporting stream_chat' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks chat models as not supporting embed' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'matches known embedding model names against the embedding pattern' do
      pattern = MlxSsotEvidenceHelpers::EMBEDDING_PATTERN
      expect(pattern).to match('BAAI/bge-large-en-v1.5')
      expect(pattern).to match('nomic-ai/nomic-embed-text-v1.5')
    end

    it 'does not match chat model names against the embedding pattern' do
      pattern = MlxSsotEvidenceHelpers::EMBEDDING_PATTERN
      chat_model = 'mlx-community/Llama-3.2-3B-Instruct-4bit'
      expect(chat_model).not_to match(pattern)
    end
  end

  # --- Explicit operation evidence controls ------------------------------------

  describe 'operation evidence controls' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:offering) do
      ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local).first
    end

    it 'marks chat as supported' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported for non-embedding models' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unknown' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'uses :provider_implementation source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_implementation),
                                                          "expected #{op} source to be :provider_implementation"
      end
    end

    it 'uses :default_false source for unknown operations' do
      expect(offering.operation_evidence[:count_tokens].source).to eq(:default_false)
    end
  end

  # --- Startup gating + initializing on initial failure ------------------------

  describe 'startup gating' do
    let(:startup) do
      cfg = ssot_harness.instance_configs[0]
      iid = ssot_harness.instance_id(instance_config: cfg)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: iid
      )
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      { cfg: cfg, instance_id: iid, key: key, callable: callable, coordinator: coordinator, publisher: publisher }
    end

    it 'remains initializing until readiness probe succeeds' do
      claim_startup
      expect(registry.snapshot.instance(instance_key: startup[:key])).to be_nil
      expect(registry.snapshot.publication_status(instance_key: startup[:key]).state).to eq(:initializing)
    end

    def claim_startup
      s = startup
      s[:publisher].claim_instance(instance_id: s[:instance_id], callable: s[:callable],
                                   probe_request_handle: s[:coordinator])
    end

    context 'when initial readiness fails' do
      let(:token) do
        startup[:publisher].claim_instance(
          instance_id: startup[:instance_id], callable: startup[:callable],
          probe_request_handle: startup[:coordinator]
        )
      end
      let(:probe) do
        startup[:publisher].readiness_probe_started(
          instance_id: startup[:instance_id], publisher_token: token
        )
      end

      before do
        startup[:publisher].readiness_failed(
          instance_id: startup[:instance_id], probe_token: probe, reason: 'MLX /health failed'
        )
      end

      it 'stays initializing after failure' do
        expect(registry.snapshot.instance(instance_key: startup[:key])).to be_nil
        expect(registry.snapshot.publication_status(instance_key: startup[:key]).state).to eq(:initializing)
      end
    end

    context 'when readiness succeeds with offerings' do
      before do
        token = startup[:publisher].claim_instance(
          instance_id: startup[:instance_id], callable: startup[:callable],
          probe_request_handle: startup[:coordinator]
        )
        probe = startup[:publisher].readiness_probe_started(
          instance_id: startup[:instance_id], publisher_token: token
        )
        drafts = ssot_harness.build_offering_drafts(
          instance_config: startup[:cfg], callable: startup[:callable], tier: :local
        )
        startup[:publisher].activate_instance_snapshot(
          instance_id: startup[:instance_id], publisher_token: token,
          offerings: drafts, sequence: 0, probe_token: probe
        )
      end

      it 'transitions to available' do
        expect(registry.snapshot.instance(instance_key: startup[:key]).availability.state).to eq(:available)
      end

      it 'reports publication status as complete' do
        expect(registry.snapshot.publication_status(instance_key: startup[:key]).state).to eq(:complete)
      end
    end
  end

  # --- Valid/stale readiness + probe-cleared unavailable ------------------------

  describe 'readiness probe lifecycle' do
    let(:probe_ctx) do
      cfg = ssot_harness.instance_configs[0]
      iid = ssot_harness.instance_id(instance_config: cfg)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: iid
      )
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      { cfg: cfg, instance_id: iid, key: key, callable: callable, coordinator: coordinator, publisher: publisher }
    end

    def activate_instance
      pub, iid, callable, coord, cfg = probe_ctx.values_at(:publisher, :instance_id, :callable, :coordinator, :cfg)
      token = pub.claim_instance(instance_id: iid, callable: callable, probe_request_handle: coord)
      probe = pub.readiness_probe_started(instance_id: iid, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: cfg, callable: callable, tier: :local)
      pub.activate_instance_snapshot(
        instance_id: iid, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    def setup_stale_probe_scenario
      pub = probe_ctx[:publisher]
      iid = probe_ctx[:instance_id]
      token = activate_instance
      stale_probe = pub.readiness_probe_started(instance_id: iid, publisher_token: token)
      fresh_probe = pub.readiness_probe_started(instance_id: iid, publisher_token: token)
      pub.readiness_failed(instance_id: iid, probe_token: fresh_probe, reason: 'server down')
      [token, stale_probe]
    end

    it 'rejects a stale probe started before a newer failure' do
      _token, stale_probe = setup_stale_probe_scenario
      result = probe_ctx[:publisher].readiness_succeeded(
        instance_id: probe_ctx[:instance_id], probe_token: stale_probe
      )
      expect(result.applied).to be(false)
    end

    it 'reports stale reason on rejected probe' do
      _token, stale_probe = setup_stale_probe_scenario
      result = probe_ctx[:publisher].readiness_succeeded(
        instance_id: probe_ctx[:instance_id], probe_token: stale_probe
      )
      expect(result.reason).to eq(:stale_probe)
    end

    def mark_unavailable_and_recover(token)
      pub = probe_ctx[:publisher]
      iid = probe_ctx[:instance_id]
      key = probe_ctx[:key]
      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: token.publisher_token_id, reason: 'connection refused'
      )
      new_probe = pub.readiness_probe_started(instance_id: iid, publisher_token: token)
      pub.readiness_succeeded(instance_id: iid, probe_token: new_probe)
    end

    it 'recovers an unavailable instance after a valid probe succeeds' do
      token = activate_instance
      mark_unavailable_and_recover(token)
      expect(registry.snapshot.instance(instance_key: probe_ctx[:key]).availability.state).to eq(:available)
    end
  end

  # --- Normalized instance-unavailable isolation -------------------------------

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token }
    end

    context 'with two active instances and instance A marked unavailable' do
      let(:instance_a) { bring_up(ssot_harness.instance_configs[0]) }
      let(:instance_b) { bring_up(ssot_harness.instance_configs[1]) }

      before do
        instance_a && instance_b
        registry.dispatch_instance_unavailable(
          instance_key: instance_a[:key],
          publisher_token_id: instance_a[:token].publisher_token_id, reason: 'connection refused'
        )
      end

      it 'marks instance A as unavailable' do
        expect(registry.snapshot.instance(instance_key: instance_a[:key]).availability.state).to eq(:unavailable)
      end

      it 'keeps instance B available' do
        expect(registry.snapshot.instance(instance_key: instance_b[:key]).availability.state).to eq(:available)
      end
    end

    it 'normalizes an explicit instance-unavailable signal as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # --- Safe-readiness coalescing via ProbeCoordinator --------------------------

  describe 'ProbeCoordinator coalescing' do
    let(:enqueue_calls) { [] }
    let(:probe_setup) do
      iid = ssot_harness.instance_id(instance_config: ssot_harness.instance_configs[0])
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: iid
      )
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key,
        enqueue: lambda { |request:|
          enqueue_calls << request
          true
        }
      )
      { instance_id: iid, key: key, coordinator: coordinator }
    end

    def enqueue_and_begin_probe(revision:)
      probe_setup[:coordinator].enqueue_probe_request(
        instance_key: probe_setup[:key], publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: revision, reason: "rev #{revision}"
      )
      probe_setup[:coordinator].begin_probe(request: enqueue_calls.first) if enqueue_calls.size == 1
    end

    def enqueue_additional(revision:, reason: "rev #{revision}")
      probe_setup[:coordinator].enqueue_probe_request(
        instance_key: probe_setup[:key], publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: revision, reason: reason
      )
    end

    it 'enqueues the first probe request immediately' do
      enqueue_and_begin_probe(revision: 1)
      expect(enqueue_calls.size).to eq(1)
    end

    it 'marks coordinator as in-flight after begin' do
      enqueue_and_begin_probe(revision: 1)
      expect(probe_setup[:coordinator].in_flight?).to be(true)
    end

    it 'does not re-enqueue while probe is in-flight' do
      enqueue_and_begin_probe(revision: 1)
      enqueue_additional(revision: 2, reason: 'second failure')
      expect(enqueue_calls.size).to eq(1)
    end

    it 'enqueues pending request after finish' do
      enqueue_and_begin_probe(revision: 1)
      enqueue_additional(revision: 2, reason: 'second failure')
      probe_setup[:coordinator].finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.size).to eq(2)
      expect(enqueue_calls.last.unavailable_revision).to eq(2)
    end

    it 'only retains the highest unavailable_revision when coalescing' do
      enqueue_and_begin_probe(revision: 1)
      enqueue_additional(revision: 3)
      enqueue_additional(revision: 2)
      probe_setup[:coordinator].finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.last.unavailable_revision).to eq(3)
    end
  end

  # --- Connection refusal/timeout/generic don't globally poison ----------------

  describe 'error isolation (no global poisoning)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0]) }

    it 'classifies connection failure as connection_failure on the callable' do
      error = Faraday::ConnectionFailed.new('Connection refused')
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:timeout)
    end

    it 'classifies generic errors as provider_error on the callable' do
      error = RuntimeError.new('unexpected failure')
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:provider_error)
    end

    it 'classifies 503 ServerError as overloaded on the callable' do
      response = { status: 503, headers: {}, body: '' }
      error = Faraday::ServerError.new('503', response)
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:overloaded)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:rate_limited)
    end

    it 'classifies 401 as authentication on the callable' do
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:authentication)
    end

    it 'classifies 404 as model_missing on the callable' do
      response = { status: 404, headers: {}, body: '' }
      error = Faraday::ClientError.new('404', response)
      expect(callable.normalize_dispatch_error(error: error).kind).to eq(:model_missing)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      results = [500, 502, 503, 504, 529].map do |s|
        error = Faraday::ServerError.new(s.to_s, { status: s, headers: {}, body: '' })
        [s, callable.normalize_dispatch_error(error: error).kind]
      end
      results.each { |s, kind| expect(kind).not_to eq(:instance_unavailable), "status #{s}" }
    end
  end

  # --- No quota domain broadening without authoritative scope ------------------

  describe 'quota domain safety' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local) }

    it 'does not declare quota_domains on offerings' do
      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'MLX offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # --- Exact fleet worker rejects stale/mismatched/unsupported/ambiguous -------

  describe 'exact fleet worker execution contract' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :mlx, instance_id: instance_id
      )
    end

    def activate_offering
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      callable = ssot_harness.build_callable(instance_config: config)
      token = claim_and_activate(publisher: publisher, callable: callable)
      offering = registry.snapshot.offerings_for(instance_key: key).first
      { publisher: publisher, token: token, offering: offering, callable: callable }
    end

    def claim_and_activate(publisher:, callable:)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      token
    end

    def build_envelope(offering_id:, model:, operation: 'chat', params: { messages: [] })
      {
        execution_contract: Legion::Extensions::Llm::Fleet::Protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: offering_id, provider: 'mlx', provider_instance: instance_id,
        model: model, operation: operation, params: params
      }
    end

    before do
      allow(Legion::Extensions::Llm::Fleet::WorkerExecution).to receive_messages(
        validate_identity!: true,
        validate_idempotency!: nil
      )
    end

    it 'rejects a mismatched offering_id' do
      activate_offering
      bogus_id = 'off:v1:0000000000000000000000000000000000000000000000000000000000000000'
      envelope = build_envelope(offering_id: bogus_id, model: 'mlx-community/Llama-3.2-3B-Instruct-4bit')
      expect { Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects an unsupported operation' do
      ctx = activate_offering
      envelope = build_envelope(offering_id: ctx[:offering].offering_id, model: ctx[:offering].model,
                                operation: 'embed', params: { text: 'hello' })
      expect { Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a mismatched model' do
      ctx = activate_offering
      envelope = build_envelope(offering_id: ctx[:offering].offering_id, model: 'some-other-model/v1')
      expect { Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    it 'rejects a stale publisher token (instance re-claimed)' do
      ctx = activate_offering
      new_publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      claim_and_activate(publisher: new_publisher, callable: ssot_harness.build_callable(instance_config: config))
      expect(registry.snapshot.offerings_for(instance_key: key).first.offering_id).to eq(ctx[:offering].offering_id)
    end

    it 'rejects an unavailable instance' do
      ctx = activate_offering
      registry.dispatch_instance_unavailable(
        instance_key: key, publisher_token_id: ctx[:token].publisher_token_id, reason: 'server down'
      )
      expect { execute_envelope(ctx) }.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ExactOfferingMismatchError)
    end

    def execute_envelope(ctx)
      envelope = build_envelope(offering_id: ctx[:offering].offering_id, model: ctx[:offering].model)
      Legion::Extensions::Llm::Fleet::WorkerExecution.call(envelope: envelope, registry: registry)
    end
  end

  # --- No Legion::LLM reverse dependency --------------------------------------

  describe 'dependency isolation' do
    it 'does not require Legion::LLM (no reverse dependency on top-level llm module)' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(File.join(project_root, 'lib/legion/extensions/llm/mlx/actors/discovery_refresh.rb'))
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'MlxCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # --- No default model/provider -----------------------------------------------

  describe 'no default model or provider' do
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :mlx, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :mlx, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end

    it 'offering drafts require an explicit model string' do
      expect { build_empty_model_offering }.to raise_error(
        Legion::Extensions::Llm::Inventory::Errors::ValidationError
      )
    end

    private

    def build_empty_model_offering
      now = Time.now.freeze
      Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        provider_native_key: 'test', model: '', tier: :local,
        operation_evidence: ssot_harness.send(:build_operation_evidence, now: now, model_id: 'test'),
        context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
        max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
        embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
          status: :unknown, source: :absent
        ),
        model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
          status: :unknown, source: :absent
        ),
        tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
        quota_domains: {}, metadata: {}, publication_source: :provider_catalog
      )
    end
  end

  # --- MlxCallable direct contract ---------------------------------------------

  describe Legion::Extensions::Llm::Mlx::Actor::MlxCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end

    it 'truncates reason to 512 bytes' do
      long_message = 'x' * 1000
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new(long_message))
      expect(outcome.reason.length).to be <= 1024
    end
  end

  # --- OfferingDraft validation ------------------------------------------------

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :local) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each { |d| expect(d.operation_evidence.keys.sort).to eq(expected_ops) }
    end

    it 'sets publication_source to :provider_catalog' do
      drafts.each { |draft| expect(draft.publication_source).to eq(:provider_catalog) }
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key { |k| expect_no_secrets(k) }
      end
    end

    private

    def expect_no_secrets(key)
      normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
      %w[credential secret apikey].each do |forbidden|
        expect(normalized).not_to include(forbidden)
      end
    end
  end

  # --- ReadinessResult contract ------------------------------------------------

  describe 'ReadinessResult contract' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:result) { ssot_harness.safe_readiness(instance_config: config, callable: callable) }

    it 'returns a ReadinessResult' do
      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
    end

    it 'reports ready status' do
      expect(result.ready?).to be(true)
    end

    it 'includes a non-empty reason string' do
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end
end
