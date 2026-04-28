# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Mlx do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'mlx-community/Qwen3-14B-4bit', provider: :mlx) }

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:mlx)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('http://localhost:8000')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:mlx)).to eq(described_class::Provider)
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
    expect(parsed_models.map(&:capabilities)).to eq([%w[streaming function_calling], %w[embeddings]])
    expect(parsed_models.map { |model| model.modalities.to_h }).to eq(expected_modalities)
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
