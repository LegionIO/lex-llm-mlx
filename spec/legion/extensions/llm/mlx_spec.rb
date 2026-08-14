# frozen_string_literal: true

require 'spec_helper'

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
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive_messages(socket_open?: false, setting: nil)
    end

    it 'returns an empty hash when no local server or settings are available' do
      expect(described_class.discover_instances).to eq({})
    end

    it 'discovers a :local instance when port 8000 is reachable' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:socket_open?)
        .with('localhost', 8000, timeout: 0.1).and_return(true)

      instances = described_class.discover_instances

      expect(instances[:local]).to eq(base_url: 'http://localhost:8000', tier: :local, capabilities: [:completion])
    end

    it 'discovers named instances from extension settings' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :mlx, :instances)
        .and_return({ gpu1: { base_url: 'http://gpu1:8080' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).to include(mlx_api_base: 'http://gpu1:8080', tier: :direct)
    end

    it 'removes base_url key after normalization' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :mlx, :instances)
        .and_return({ gpu1: { base_url: 'http://gpu1:8080' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).not_to have_key(:base_url)
    end

    it 'normalizes OpenAI-compatible /v1 settings roots' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :mlx, :instances)
        .and_return({ gpu1: { base_url: 'http://gpu1:8080/v1', api_key: 'mlx-key' } })
      instances = described_class.discover_instances
      expect(instances[:gpu1]).to include(mlx_api_base: 'http://gpu1:8080', mlx_api_key: 'mlx-key', tier: :direct)
    end

    it 'combines local and settings instances' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:socket_open?)
        .with('localhost', 8000, timeout: 0.1).and_return(true)
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :mlx, :instances).and_return({ remote: { base_url: 'http://remote:8080' } })
      expect(described_class.discover_instances.keys).to contain_exactly(:local, :remote)
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
