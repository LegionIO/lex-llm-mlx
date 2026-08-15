# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/mlx/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Mlx::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'mlx', provider_instance: 'local', operation: 'chat' } }

  before do
    allow(Legion::Extensions::Llm::Mlx).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)
  end

  it 'returns the responder result' do
    result = described_class.handle_fleet_request(**payload)
    expect(result).to eq(:ok)
  end

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    described_class.handle_fleet_request(**payload)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder)
      .to have_received(:call).with(
        hash_including(payload: payload, provider_family: :mlx, delivery: nil, properties: nil)
      )
  end

  it 'accepts the transport metadata merged in by the Subscription actor' do
    message = payload.merge(routing_key: 'llm.fleet.mlx.local', message_id: 'm-1', timestamp: 1)
    described_class.handle_fleet_request(**message)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder)
      .to have_received(:call).with(hash_including(payload: message, provider_family: :mlx))
  end
end
