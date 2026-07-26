# frozen_string_literal: true

require 'test_helper'

# Emission pipeline (Lot 3), driven by a shared Fake gateway (Qonto e-invoicing
# only exists in production, so it is never exercised for real here).
class Qonto::EmissionPipelineTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @sale = sales(:sales_001)
    @fake = EInvoicing::Adapters::Fake.new(reachable: true)
  end

  def test_send_marks_submitted_with_remote_id
    outbound = with_gateway(@fake) { Qonto::SendEInvoiceService.call(@sale) }
    assert_equal 'submitted', outbound.status
    assert outbound.remote_id.present?
    assert outbound.submitted_at.present?
  end

  def test_send_marks_failed_when_recipient_unreachable
    unreachable = EInvoicing::Adapters::Fake.new(reachable: false)
    outbound = with_gateway(unreachable) { Qonto::SendEInvoiceService.call(@sale) }
    assert outbound.failed?
    assert_equal 'recipient_not_reachable_on_einvoicing', outbound.last_error['code']
  end

  def test_send_is_idempotent_once_submitted
    with_gateway(@fake) do
      first = Qonto::SendEInvoiceService.call(@sale)
      assert_no_difference 'Qonto::OutboundInvoice.count' do
        again = Qonto::SendEInvoiceService.call(@sale)
        assert_equal first.id, again.id
        assert_equal 'submitted', again.status
      end
    end
  end

  def test_refresh_advances_submitted_then_issued_then_received
    with_gateway(@fake) do
      outbound = Qonto::SendEInvoiceService.call(@sale)
      rid = outbound.remote_id

      Qonto::RefreshEInvoiceService.call(outbound)
      assert_equal 'submitted', outbound.reload.status # only 200 (deposited) so far

      @fake.advance(rid) # → 201 issued
      Qonto::RefreshEInvoiceService.call(outbound)
      assert_equal 'issued', outbound.reload.status
      assert outbound.issued_at.present?

      @fake.advance(rid) # → 202 received
      Qonto::RefreshEInvoiceService.call(outbound)
      assert outbound.reload.received?
      assert outbound.received_at.present?
      assert_equal 3, outbound.lifecycle_events.size
    end
  end

  def test_retry_after_failure_resubmits
    with_gateway(EInvoicing::Adapters::Fake.new(reachable: false)) { Qonto::SendEInvoiceService.call(@sale) }
    assert Qonto::OutboundInvoice.find_by(sale: @sale).failed?

    outbound = with_gateway(EInvoicing::Adapters::Fake.new(reachable: true)) { Qonto::SendEInvoiceService.call(@sale) }
    assert_equal 'submitted', outbound.status
  end

  private

    def with_gateway(gateway)
      result = nil
      EInvoicing::Gateway.stub(:build, gateway) { result = yield }
      result
    end
end
