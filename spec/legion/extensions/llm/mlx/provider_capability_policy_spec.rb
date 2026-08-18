# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Mlx::Provider do
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
    it 'excludes tools capability for an unknown model id' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capabilities).not_to include(:tools)
    end

    it 'excludes vision capability for an unknown model id' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capabilities).not_to include(:vision)
    end

    it 'excludes embeddings capability for an unknown model id' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capabilities).not_to include(:embeddings)
    end

    it 'excludes thinking capability for an unknown model id' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capabilities).not_to include(:thinking)
    end

    it 'reports tools source as default_false for unknown model' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capability_sources[:tools]).to eq({ value: false, source: :default_false })
    end

    it 'reports vision source as default_false for unknown model' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capability_sources[:vision]).to eq({ value: false, source: :default_false })
    end

    it 'reports thinking source as default_false for unknown model' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capability_sources[:thinking]).to eq({ value: false, source: :default_false })
    end

    it 'does not include streaming for an unknown model without endpoint evidence' do
      offering = provider.send(:offering_from_model, bare_model)
      expect(offering.capabilities).not_to include(:streaming)
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
    let(:tools_configured) { configured_with(tools_flag: true) }

    it 'applies tools_flag from instance config as :instance_override' do
      offering = tools_configured.send(:offering_from_model, bare_model)
      expect(offering.capabilities).to include(:tools)
    end

    it 'reports tools source as instance_override' do
      offering = tools_configured.send(:offering_from_model, bare_model)
      expect(offering.capability_sources[:tools]).to eq({ value: true, source: :instance_override })
    end
  end

  describe 'model override' do
    let(:model_cfg) { { 'mlx-community/custom-unknown-model' => { embedding_flag: true, tools_flag: false } } }

    it 'applies model-level overrides as :model_override' do
      configured = configured_with(models: model_cfg)
      offering = configured.send(:offering_from_model, bare_model)
      expect(offering.capabilities).to include(:embedding)
      expect(offering.capabilities).not_to include(:tools)
    end

    it 'reports model-level capability sources as model_override' do
      configured = configured_with(models: model_cfg)
      offering = configured.send(:offering_from_model, bare_model)
      expect(offering.capability_sources[:embedding]).to eq({ value: true, source: :model_override })
      expect(offering.capability_sources[:tools]).to eq({ value: false, source: :model_override })
    end
  end

  describe 'shared offering contract' do
    let(:configured_with_tier) do
      described_class.new(
        mlx_api_base: 'http://localhost:8000',
        tier: :direct
      )
    end

    it 'honors tier overrides and carries provider health onto offerings' do
      offering = configured_with_tier.send(:offering_from_model, bare_model, health: { status: 'healthy', ready: true })

      expect(offering.tier).to eq(:direct)
      expect(offering.health).to eq({ status: 'healthy', ready: true })
    end
  end

  def configured_with(opts)
    described_class.new(mlx_api_base: 'http://localhost:8000', **opts)
  end
end
