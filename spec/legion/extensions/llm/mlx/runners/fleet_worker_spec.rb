# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/mlx/runners/fleet_worker'

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Mlx::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'mlx', provider_instance: 'local' } }
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }

  before do
    allow(Legion::Extensions::Llm::Mlx).to receive(:discover_instances).and_return(instances)
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)
  end

  it 'returns the responder result' do
    result = described_class.handle_fleet_request(payload, delivery:, properties:)
    expect(result).to eq(:ok)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    described_class.handle_fleet_request(payload, delivery:, properties:)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder)
      .to have_received(:call).with(hash_including(payload:, provider_family: :mlx, delivery:, properties:))
  end
end
