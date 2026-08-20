# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/mlx/provider'
require 'legion/extensions/llm/mlx/actors/discovery_refresh'

RSpec.describe Legion::Extensions::Llm::Mlx::Provider do
  describe '0.8.0 funnel shape (08 F1/F3)' do
    it 'takes completion messages positionally, like the base funnel and the kit B1/B2 callable' do
      %i[chat stream_chat].each do |method_name|
        params = described_class.instance_method(method_name).parameters
        expect(params.first).to eq(%i[req messages]),
                                "#{method_name} must take positional canonical messages"
        expect(params).to include(%i[keyreq model]), "#{method_name} must take a named model"
      end
    end

    it 'keeps named text/prompt for the non-completion operations' do
      expect(described_class.instance_method(:embed).parameters).to include(%i[keyreq text])
      expect(described_class.instance_method(:image).parameters).to include(%i[keyreq prompt])
      expect(described_class.instance_method(:count_tokens).parameters).to include(%i[keyreq messages])
    end
  end

  describe '#discover_offerings' do
    # 0.8.0 read path (07 C5 / 08 D3): the base serves the activated inventory
    # offerings for this instance from the Registry snapshot — the legacy
    # offering production (Routing::ModelOffering) is deleted; the per-gem
    # writer (the discovery actor) is the sole publication path.
    let(:model_id) { 'mlx-community/custom-unknown-model' }
    let(:provider) { described_class.new(mlx_api_base: 'http://localhost:8000', instance_id: :default) }
    let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: :mlx, instance_id: 'default')
    end

    before do
      registry.reset!
      draft = Legion::Extensions::Llm::Mlx::Actor::DiscoveryRefresh.new.send(
        :build_offering_draft,
        model_id: model_id,
        model_data: { id: model_id, max_model_len: 32_768 },
        instance_cfg: { mlx_api_base: 'http://localhost:8000', tier: :local },
        instance_key: key
      )
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :mlx)
      callable = Legion::Extensions::Llm::Mlx::Actor::MlxCallable.new(
        instance_cfg: { mlx_api_base: 'http://localhost:8000' }, logger: Logger.new(File::NULL)
      )
      token = publisher.claim_instance(
        instance_id: 'default', callable: callable,
        probe_request_handle: Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
          instance_key: key, enqueue: ->(**) { true }
        )
      )
      probe = publisher.readiness_probe_started(instance_id: 'default', publisher_token: token)
      publisher.activate_instance_snapshot(
        instance_id: 'default', publisher_token: token, offerings: [draft], sequence: 0, probe_token: probe
      )
    end

    after { registry.reset! }

    it 'serves the activated inventory offerings from the Registry snapshot' do
      offerings = provider.discover_offerings

      expect(offerings.map(&:model)).to eq([model_id])
    end

    it 'filters snapshot offerings by model' do
      expect(provider.discover_offerings(model: 'some-other-model')).to be_empty
    end
  end
end
