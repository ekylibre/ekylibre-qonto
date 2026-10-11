# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# Sending the same sale twice would put two invoices in front of the client.
class Qonto::SendEInvoiceServiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  # Records how it was called, and plays a scripted outcome.
  class RecordingGateway < EInvoicing::Gateway
    attr_reader :calls

    # outcome: :ok | :fail_after_creation | :fail | :boom
    def initialize(outcome = :ok)
      @outcome = outcome
      @calls = []
    end

    def submit(sale, remote_id: nil, on_created: nil)
      @calls << { sale: sale.id, remote_id: remote_id }
      raise 'the platform exploded' if @outcome == :boom
      return EInvoicing::Gateway::Result.failure('recipient_not_reachable_on_einvoicing', 'no') if @outcome == :fail

      remote_id ||= 'draft-1'.tap { |id| on_created&.call(id) }
      return EInvoicing::Gateway::Result.failure('invoice_not_in_draft_status', 'x') if @outcome == :fail_after_creation

      EInvoicing::Gateway::Result.success(remote_id)
    end
  end

  setup do
    @sale = sales(:sales_001)
  end

  def test_submits_and_records_the_remote_invoice
    gateway = RecordingGateway.new
    outbound = run_with(gateway)

    assert_equal 'submitted', outbound.status
    assert_equal 'draft-1', outbound.remote_id
    assert outbound.submitted_at
    assert_equal 1, gateway.calls.size
    assert_equal({ sale: @sale.id, remote_id: nil }, gateway.calls.first)
  end

  def test_a_failed_sending_is_recorded_with_its_reason
    outbound = run_with(RecordingGateway.new(:fail))

    assert_equal 'failed', outbound.status
    assert_equal 'recipient_not_reachable_on_einvoicing', outbound.last_error['code']
  end

  # -- never twice -----------------------------------------------------------

  def test_a_sale_already_submitted_is_not_submitted_again
    gateway = RecordingGateway.new
    run_with(gateway)
    run_with(gateway)

    assert_equal 1, gateway.calls.size
    assert_equal 1, Qonto::OutboundInvoice.where(sale: @sale).count
  end

  def test_a_sending_in_progress_is_left_alone
    # The second click's job arrives while the first worker is still talking to the platform.
    Qonto::OutboundInvoice.create!(sale: @sale, status: 'submitting')
    gateway = RecordingGateway.new

    outbound = run_with(gateway)

    assert_empty gateway.calls
    assert_equal 'submitting', outbound.status
  end

  def test_a_sending_abandoned_by_a_dead_worker_is_taken_over
    abandoned = Qonto::OutboundInvoice.create!(sale: @sale, status: 'submitting')
    abandoned.update_columns(updated_at: (Qonto::OutboundInvoice::SUBMITTING_STALE_AFTER + 1.minute).ago)
    gateway = RecordingGateway.new

    outbound = run_with(gateway)

    assert_equal 1, gateway.calls.size
    assert_equal 'submitted', outbound.status
  end

  def test_the_claim_is_taken_before_talking_to_the_platform
    seen = nil
    gateway = RecordingGateway.new
    gateway.define_singleton_method(:submit) do |sale, **|
      seen = Qonto::OutboundInvoice.find_by(sale: sale).status
      EInvoicing::Gateway::Result.success('draft-1')
    end

    run_with(gateway)
    assert_equal 'submitting', seen, 'a concurrent job would see it taken'
  end

  def test_a_job_that_loses_the_race_to_create_the_row_uses_the_winner_row
    winner = Qonto::OutboundInvoice.create!(sale: @sale, status: 'submitting')
    raise_unique = ->(*) { raise ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint' }
    gateway = RecordingGateway.new

    outbound = Qonto::OutboundInvoice.stub(:find_or_create_by!, raise_unique) { run_with(gateway) }

    assert_equal winner.id, outbound.id
    assert_empty gateway.calls, 'the winner is the one sending'
  end

  # -- no second draft after a failure ---------------------------------------

  def test_the_invoice_created_on_the_platform_is_remembered_even_when_the_sending_fails
    outbound = run_with(RecordingGateway.new(:fail_after_creation))

    assert_equal 'failed', outbound.status
    assert_equal 'draft-1', outbound.remote_id, 'known, so a retry can send it instead of creating another'
  end

  def test_a_retry_sends_the_existing_invoice_instead_of_creating_another
    run_with(RecordingGateway.new(:fail_after_creation))
    gateway = RecordingGateway.new

    outbound = run_with(gateway)

    assert_equal 'draft-1', gateway.calls.first[:remote_id]
    assert_equal 'submitted', outbound.status
    assert_equal 'draft-1', outbound.remote_id
  end

  def test_a_retry_of_a_failure_without_remote_invoice_starts_from_scratch
    run_with(RecordingGateway.new(:fail))
    gateway = RecordingGateway.new

    run_with(gateway)
    assert_nil gateway.calls.first[:remote_id]
  end

  # -- never stuck -----------------------------------------------------------

  def test_an_exception_does_not_leave_the_sale_stuck_in_submitting
    assert_raises(RuntimeError) { run_with(RecordingGateway.new(:boom)) }

    outbound = Qonto::OutboundInvoice.find_by(sale: @sale)
    assert_equal 'failed', outbound.status
    assert_equal 'exception', outbound.last_error['code']
    assert_match(/exploded/, outbound.last_error['detail'])
    assert outbound.claimable?, 'the user can retry'
  end

  private

    def run_with(gateway)
      EInvoicing::Gateway.stub(:build, gateway) { Qonto::SendEInvoiceService.call(@sale) }
    end
end
