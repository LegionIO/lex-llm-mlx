# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/mlx/actors/fleet_worker'
require 'legion/extensions/llm/mlx/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Mlx::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'resolves the fleet runner as a constant (Subscription dispatch calls runner_class.send)' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Mlx::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'dispatches a fleet message through the runner module' do
    allow(Legion::Extensions::Llm::Mlx::Runners::FleetWorker).to receive(:handle_fleet_request)
      .and_return({ status: 'ok' })

    result = actor.runner_class.send(actor.runner_function, request_id: 'req-9', provider: 'mlx')
    expect(result).to eq(status: 'ok')
    expect(Legion::Extensions::Llm::Mlx::Runners::FleetWorker)
      .to have_received(:handle_fleet_request).with(hash_including(request_id: 'req-9', provider: 'mlx'))
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Mlx).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end

  it 'is disabled when no instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Mlx).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: false } })

    expect(actor.enabled?).to be(false)
  end
end
