# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Mlx::Provider do # rubocop:disable RSpec/SpecFilePathFormat
  let(:provider) { described_class.new(Legion::Extensions::Llm.config) }

  let(:bare_model) do
    Legion::Extensions::Llm::Model::Info.from_hash(
      id: 'mlx-community/custom-unknown-model', name: 'custom-unknown-model', provider: :mlx,
      capabilities: [], metadata: {}
    )
  end

  before do
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
  end

  describe 'unknown model defaults' do
    it 'defaults optional capabilities to false for an unknown model id' do # rubocop:disable RSpec/ExampleLength
      offering = provider.send(:offering_from_model, bare_model)

      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capabilities).not_to include(:vision)
      expect(offering.capabilities).not_to include(:embeddings)
      expect(offering.capabilities).not_to include(:thinking)
      expect(offering.capability_sources[:tools]).to eq({ value: false, source: :default_false })
      expect(offering.capability_sources[:vision]).to eq({ value: false, source: :default_false })
      expect(offering.capability_sources[:thinking]).to eq({ value: false, source: :default_false })
    end

    it 'includes streaming from provider_catalog for a chat model' do
      offering = provider.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:streaming)
      expect(offering.capability_sources[:streaming][:source]).to eq(:provider_catalog)
    end
  end

  describe 'provider-root override' do
    it 'applies streaming_flag from provider config as :provider_override' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :mlx).and_return({ streaming_flag: true })

      offering = provider.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:streaming)
      expect(offering.capability_sources[:streaming]).to eq({ value: true, source: :provider_override })
    end
  end

  describe 'instance override' do
    it 'applies tools_flag from instance config as :instance_override' do # rubocop:disable RSpec/ExampleLength
      configured = described_class.new(
        mlx_api_base: 'http://localhost:8000',
        tools_flag: true
      )

      offering = configured.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:tools)
      expect(offering.capability_sources[:tools]).to eq({ value: true, source: :instance_override })
    end
  end

  describe 'model override' do
    it 'applies model-level overrides as :model_override' do # rubocop:disable RSpec/ExampleLength
      configured = described_class.new(
        mlx_api_base: 'http://localhost:8000',
        models: { 'mlx-community/custom-unknown-model' => { embedding_flag: true, tools_flag: false } }
      )

      offering = configured.send(:offering_from_model, bare_model)

      expect(offering.capabilities).to include(:embeddings)
      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capability_sources[:embeddings]).to eq({ value: true, source: :model_override })
      expect(offering.capability_sources[:tools]).to eq({ value: false, source: :model_override })
    end
  end
end
