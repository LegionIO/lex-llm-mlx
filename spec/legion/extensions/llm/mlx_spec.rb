# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/mlx/runners/discovery'

RSpec.describe Legion::Extensions::Llm::Mlx do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { 'mlx-community/Qwen3-14B-4bit' }

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

  # 0.8.0: model → operation knowledge is published by the discovery runner's
  # build_offering_draft (operation_evidence), not a provider-side catalog
  # parser. The chat-vs-embeddings routing fact is asserted at that owner.
  it 'maps discovered chat and embedding models to explicit operation evidence' do
    instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :mlx, instance_id: 'default'
    )
    cfg = { mlx_api_base: 'http://localhost:8000', tier: :local }
    chat_draft = described_class::Runners::Discovery.build_offering_draft(
      instance_cfg: cfg, instance_key: instance_key,
      model_id: 'mlx-community/Qwen3-14B-4bit',
      model_data: { id: 'mlx-community/Qwen3-14B-4bit', max_model_len: 32_768 }
    )
    embed_draft = described_class::Runners::Discovery.build_offering_draft(
      instance_cfg: cfg, instance_key: instance_key,
      model_id: 'mlx-community/nomic-embed-text',
      model_data: { id: 'mlx-community/nomic-embed-text', max_model_len: 512 }
    )

    expect(chat_draft.operation_evidence[:chat].status).to eq(:supported)
    expect(chat_draft.operation_evidence[:embed].status).to eq(:unsupported)
    expect(embed_draft.operation_evidence[:embed].status).to eq(:supported)
    expect(embed_draft.operation_evidence[:chat].status).to eq(:unsupported)
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

    it 'includes the default template in the claimable set' do
      settings_tree.replace(instances: { default: synthetic_default })

      expect(described_class.configured_instances).to have_key(:default)
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

    it 'never claims a disabled (enabled: false) instance' do
      settings_tree.replace(instances: {
                              gpu1: { base_url: 'http://gpu1:8080' },
                              gpu2: { base_url: 'http://gpu2:8080', enabled: false }
                            })

      instances = described_class.discover_instances
      expect(instances).to have_key(:gpu1)
      expect(instances).not_to have_key(:gpu2)
    end

    it 'never claims a credential-less instance with no api base' do
      settings_tree.replace(instances: { gpu1: { tier: :local } })

      expect(described_class.discover_instances).to eq({})
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
    # 0.8.0 renderer law (08 R1): render FROM canonical values — a
    # Canonical::Message plus Canonical::Params (temperature is a params
    # member, 05 O4) and the Selection-derived model string.
    message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)
    provider.send(:render_payload, [message], tools: {}, model: model, stream: false,
                                              schema: nil, thinking: nil, params: params, tool_prefs: nil)
  end
end
