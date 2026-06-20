# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/mlx/provider'

RSpec.describe Legion::Extensions::Llm::Mlx::Provider do
  it 'does not expose positional canonical provider arguments' do
    canonical_methods.each { |method_name| expect_keyword_compatible(method_name) }
  end

  describe '#discover_offerings' do
    let(:provider) do
      described_class.new(
        mlx_api_base: 'http://localhost:8000',
        model_whitelist: [],
        model_blacklist: []
      )
    end
    let(:model) do
      Legion::Extensions::Llm::Model::Info.from_hash(
        id: 'mlx-community/custom-unknown-model',
        name: 'custom-unknown-model',
        provider: :mlx,
        capabilities: []
      )
    end

    before do
      allow(provider).to receive(:health).with(live: true).and_return({ status: 'healthy', ready: true })
      allow(provider).to receive(:list_models).with(live: true).and_return([model])
    end

    it 'treats empty whitelist and blacklist as allow-all' do
      offerings = provider.discover_offerings(live: true)

      expect(offerings.map(&:model)).to eq(['mlx-community/custom-unknown-model'])
    end
  end

  def canonical_methods = %i[chat stream_chat embed image list_models discover_offerings health count_tokens]

  def expect_keyword_compatible(method_name)
    return unless described_class.method_defined?(method_name)

    params = described_class.instance_method(method_name).parameters
    expect(params).not_to include(%i[req messages]), "#{method_name} still has positional messages"
    expect(params).not_to include(%i[req text]), "#{method_name} still has positional text"
    expect(params).not_to include(%i[req prompt]), "#{method_name} still has positional prompt"
  end
end
