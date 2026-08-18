# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'

RSpec.describe Legion::Extensions::Llm::Mlx do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'mlx-community/Qwen3-14B-4bit', provider: :mlx) }

  it 'exposes provider defaults through the shared provider settings shape' do
    settings = described_class.default_settings
    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:mlx)
  end

  it 'includes endpoint default in provider settings' do
    instance = described_class.default_settings.dig(:instances, :default)
    expect(instance).to include(endpoint: 'http://localhost:8000')
  end

  it 'includes credentials and fleet defaults in provider settings' do
    instance = described_class.default_settings.dig(:instances, :default)
    expect(instance).to include(credentials: hash_including(api_key: nil),
                                fleet: hash_including(respond_to_requests: false))
  end

  it 'does not register on the deprecated Provider.register registry' do
    expect(Legion::Extensions::Llm::Provider).not_to respond_to(:providers)
  end

  it 'uses the shared OpenAI-compatible provider adapter' do
    expect(described_class::Provider.ancestors).to include(Legion::Extensions::Llm::Provider::OpenAICompatible)
  end

  it 'exposes OpenAI-compatible endpoint helpers' do
    expect([provider.api_base, provider.completion_url, provider.models_url, provider.embedding_url,
            provider.health_url])
      .to eq(['http://localhost:8000', '/v1/chat/completions', '/v1/models', '/v1/embeddings', '/health'])
  end

  it 'renders chat payloads through the shared OpenAI-compatible adapter' do
    payload = chat_payload

    expect(payload.values_at(:model, :stream, :temperature)).to eq(['mlx-community/Qwen3-14B-4bit', false, 0.2])
    expect(payload[:messages]).to eq([{ role: 'user', content: 'hello' }])
  end

  it 'uses an optional bearer token when configured' do
    original = Legion::Extensions::Llm.config.mlx_api_key
    Legion::Extensions::Llm.config.mlx_api_key = 'token-abc123'

    expect(provider.headers).to eq('Authorization' => 'Bearer token-abc123')
  ensure
    Legion::Extensions::Llm.config.mlx_api_key = original
  end

  it 'maps discovered chat and embedding models to explicit routing metadata' do
    normalized = parsed_models.map { |parsed_model| Legion::Extensions::Llm::Capabilities.normalize(parsed_model.capabilities) }

    expect(normalized).to eq([%i[streaming tools], %i[embedding]])
    expect(parsed_models.map { |model| model.modalities.to_h }).to eq(expected_modalities)
  end

  describe '.discover_instances' do
    let(:settings_tree) { Legion::Settings.loader.settings[:extensions][:llm][:mlx] }
    let(:synthetic_default) { described_class.default_settings.dig(:instances, :default) }

    after { settings_tree.replace({}) }

    it 'never fabricates instances by port-scanning' do
      # With no instances configured, nothing surfaces — no synthesized
      # :local fallback, no socket-probe result, no phantom builder.
      settings_tree.replace({})
      expect(described_class.discover_instances).to eq({})
    end

    # D3: the synthetic instances.default section (the extension's own
    # instance defaults, nested by provider_settings at boot) is an
    # unconfigured phantom while it is unmodified — it must never reach
    # the claim path. The actor's claimable set (tick_refresh iterates
    # configured_instances into claim_and_activate_instance) excludes it.
    it 'skips the synthetic default while it is the unmodified template (claimable set)' do
      settings_tree.replace(instances: { default: synthetic_default })

      expect(described_class.configured_instances).to eq({})
    end

    # The unconfigured-default skip is the NORMAL state — the operator
    # signal ("default is still the unmodified template; set a real
    # endpoint to publish it") must be loud on first skip but not
    # per-tick WARN spam. The throttle is a module-lifetime flag (once
    # per boot), so the spec resets it first: it is process-wide state,
    # and earlier examples already latch it.
    it 'warns about the synthetic default exactly once per boot across ticks' do
      described_class.instance_variable_set(:@synthetic_default_warned, false)
      settings_tree.replace(instances: { default: synthetic_default })
      warnings = []
      fake_log = Object.new
      fake_log.define_singleton_method(:warn) { |message = nil, **| warnings << message.to_s }
      allow(described_class).to receive(:log).and_return(fake_log)

      expect(described_class.configured_instances).to eq({})
      expect(described_class.configured_instances).to eq({})

      expect(warnings.size).to eq(1), 'the template skip must be loud but not per-tick spam'
      expect(warnings.first).to include('action=skip_instance')
      expect(warnings.first).to include('reason=synthetic_default')
      expect(described_class.instance_variable_get(:@synthetic_default_warned)).to be(true)
    end

    it 'excludes the synthetic default from the fleet-responder discovery set' do
      settings_tree.replace(instances: { default: synthetic_default })

      # discover_instances is the exact input to FleetWorker#enabled?'s
      # ProviderResponder.enabled_for? — the phantom localhost instance
      # must not be in it.
      expect(described_class.discover_instances).to eq({})
      expect(Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(described_class.discover_instances))
        .to be(false)
    end

    # A configured (non-template) instances.default — a real operator
    # entry with real values — is NOT the synthetic phantom: v2 parity,
    # 'default' accepted as a plain instance label. The provider layer
    # passes it to the claim path; whether the foundation accepts the
    # name is a lex-llm InstanceKey contract, not a provider-layer
    # decision (asserted on the discover/claimable set, not an
    # end-to-end claim).
    it 'passes a configured (non-template) default to the claim path' do
      settings_tree.replace(instances: { default: synthetic_default.merge(endpoint: 'http://10.0.0.5:8000') })

      instances = described_class.configured_instances
      expect(instances.keys).to eq([:default])
      expect(instances[:default]).to include(mlx_api_base: 'http://10.0.0.5:8000', tier: :local)
    end

    it 'enables the fleet responder when a configured default opts in' do
      settings_tree.replace(instances: {
                              default: synthetic_default.merge(
                                endpoint: 'http://10.0.0.5:8000',
                                fleet: { respond_to_requests: true }
                              )
                            })

      expect(Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(described_class.discover_instances))
        .to be(true)
    end

    it 'discovers named instances from extension settings' do
      settings_tree.replace(instances: { gpu1: { base_url: 'http://gpu1:8080' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).to include(mlx_api_base: 'http://gpu1:8080', tier: :local)
    end

    it 'removes base_url key after normalization' do
      settings_tree.replace(instances: { gpu1: { base_url: 'http://gpu1:8080' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).not_to have_key(:base_url)
    end

    it 'normalizes OpenAI-compatible /v1 settings roots' do
      settings_tree.replace(instances: { gpu1: { base_url: 'http://gpu1:8080/v1', api_key: 'mlx-key' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).to include(mlx_api_base: 'http://gpu1:8080', mlx_api_key: 'mlx-key', tier: :local)
    end

    it 'preserves an explicit operator tier instead of forcing one' do
      settings_tree.replace(instances: { gpu1: { base_url: 'http://gpu1:8080', tier: :direct } })
      instances = described_class.discover_instances
      expect(instances[:gpu1][:tier]).to eq(:direct)
    end

    it 'is the single source shared by the fleet responder enablement check' do
      fleet = { respond_to_requests: true }
      settings_tree.replace(instances: { gpu1: { base_url: 'http://gpu1:8080', fleet: fleet } })
      expect(Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(described_class.discover_instances))
        .to be(true)
    end
  end

  def chat_payload
    message = Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    provider.send(:render_payload, [message], tools: {}, temperature: 0.2, model: model, stream: false,
                                              schema: nil, thinking: nil, tool_prefs: nil)
  end

  def parsed_models
    provider.send(:parse_list_models_response, fake_response(models_body), :mlx,
                  described_class::Provider.capabilities)
  end

  def expected_modalities
    [
      { input: %w[text image], output: %w[text] },
      { input: %w[text], output: %w[embeddings] }
    ]
  end

  def models_body
    {
      'data' => [
        { 'id' => 'mlx-community/Qwen3-14B-4bit', 'created' => 1 },
        { 'id' => 'mlx-community/nomic-embed-text', 'created' => 2 }
      ]
    }
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end
end
