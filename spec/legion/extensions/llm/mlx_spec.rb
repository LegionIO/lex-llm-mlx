# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Mlx do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'mlx-community/Qwen3-14B-4bit', provider: :mlx) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  it 'exposes flat provider defaults with consumer-facing settings' do
    expect(described_class.default_settings).to eq(
      enabled: false, base_url: 'localhost:8000', default_model: nil, api_key: nil,
      model_whitelist: [], model_blacklist: [], model_cache_ttl: 60,
      tls: { enabled: false, verify: :peer }, instances: {}
    )
  end

  it 'does not register on the deprecated Provider.register registry' do
    expect(Legion::Extensions::Llm::Provider.providers[:mlx]).to be_nil
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
    expect(parsed_models.map(&:capabilities)).to eq([%i[streaming function_calling], %i[embeddings]])
    expect(parsed_models.map { |model| model.modalities.to_h }).to eq(expected_modalities)
  end

  it 'publishes live readiness metadata asynchronously through the base registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(provider.connection).to receive(:get).with('/health').and_return(fake_response({}))
    allow(registry_publisher).to receive(:publish_readiness_async)

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'publishes discovered models asynchronously through the base registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :mlx, live: false))
  end

  it 'builds sanitized lex-llm registry events for MLX model availability via base builder' do
    builder = Legion::Extensions::Llm::RegistryEventBuilder.new(provider_family: :mlx)
    event = builder.model_available(model, readiness: { ready: true })

    expect(event.to_h).to include(event_type: :offering_available)
    expect(event.to_h.dig(:offering, :provider_family)).to eq(:mlx)
    expect(event.to_h.dig(:offering, :model)).to eq('mlx-community/Qwen3-14B-4bit')
  end

  it 'creates the registry publisher with the :mlx provider family' do
    described_class::Provider.registry_publisher = nil
    pub = described_class::Provider.registry_publisher

    expect(pub).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(pub.provider_family).to eq(:mlx)
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

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('/v1/models').and_return(fake_response(models_body))
  end

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end
end
