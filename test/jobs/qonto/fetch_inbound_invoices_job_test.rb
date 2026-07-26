# frozen_string_literal: true

require 'test_helper'

class Qonto::FetchInboundInvoicesJobTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_fetch_imports_inbound_invoices_from_gateway
    fake = EInvoicing::Adapters::Fake.new.stub_inbound([
      { remote_id: 'g-1', supplier_name: 'ACME', supplier_siret: nil,
        invoice_number: 'A-1', currency: 'EUR', amount: 10.0, pretax_amount: 10.0,
        issued_on: Date.new(2026, 6, 1), due_on: nil, payload: { id: 'g-1' } }
    ])

    assert_difference 'Qonto::InboundInvoice.count', 1 do
      EInvoicing::Gateway.stub(:build, fake) do
        Qonto::FetchInboundInvoicesJob.perform_now
      end
    end

    assert Qonto::InboundInvoice.exists?(remote_id: 'g-1')
  end

  def test_schedulable_requires_flag_and_integration
    EInvoicing::Gateway.stub(:enabled?, false) do
      refute Qonto::FetchInboundInvoicesJob.schedulable?, 'off when feature disabled'
    end

    EInvoicing::Gateway.stub(:enabled?, true) do
      Integration.stub(:exists?, false) do
        refute Qonto::FetchInboundInvoicesJob.schedulable?, 'off without a Qonto integration'
      end
      Integration.stub(:exists?, true) do
        assert Qonto::FetchInboundInvoicesJob.schedulable?, 'on when enabled and integration present'
      end
    end
  end

  def test_fetch_is_idempotent_across_runs
    fake = EInvoicing::Adapters::Fake.new.stub_inbound([
      { remote_id: 'g-2', supplier_name: 'ACME', invoice_number: 'A-2',
        currency: 'EUR', amount: 20.0, payload: { id: 'g-2' } }
    ])

    EInvoicing::Gateway.stub(:build, fake) do
      Qonto::FetchInboundInvoicesJob.perform_now
      assert_no_difference 'Qonto::InboundInvoice.count' do
        Qonto::FetchInboundInvoicesJob.perform_now
      end
    end
  end
end
