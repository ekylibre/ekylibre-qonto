# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# The two requests of an emission (create the invoice, then send it) are not
# atomic. What happens between them must not produce a second invoice. No
# network: the integration calls are doubles.
module EInvoicing
  class QontoSubmitRetryTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
    FakeCall = Struct.new(:body, :ok) do
      def execute
        yield self
      end

      def success
        yield body if ok
      end

      def error
        yield body unless ok
      end
    end

    NOT_IN_DRAFT = { errors: [{ code: 'invoice_not_in_draft_status', detail: 'already sent' }] }.freeze
    NOT_REACHABLE = { errors: [{ code: 'recipient_not_reachable_on_einvoicing', detail: 'no' }] }.freeze

    setup do
      @sale = sales(:sales_001)
      @adapter = Adapters::Qonto.new
      @created = []
      @sent = []
    end

    def test_a_fresh_submission_creates_then_sends_and_reports_the_new_id_in_between
      announced = nil
      result = with_platform(send_outcome: true) do
        @adapter.submit(@sale, on_created: ->(id) { announced = [id, @sent.dup] })
      end

      assert result.ok?
      assert_equal 'inv-1', result.value
      assert_equal 1, @created.size
      assert_equal ['inv-1'], @sent
      assert_equal ['inv-1', []], announced, 'announced before the sending was requested'
    end

    def test_a_failed_sending_still_leaves_the_caller_the_id_of_the_created_invoice
      announced = nil
      result = with_platform(send_outcome: NOT_REACHABLE) { @adapter.submit(@sale, on_created: ->(id) { announced = id }) }

      refute result.ok?
      assert_equal 'recipient_not_reachable_on_einvoicing', result.error_code
      assert_equal 'inv-1', announced
    end

    def test_retrying_with_the_id_only_sends_and_creates_nothing
      result = with_platform(send_outcome: true) { @adapter.submit(@sale, remote_id: 'inv-1') }

      assert result.ok?
      assert_equal 'inv-1', result.value
      assert_empty @created, 'no second invoice'
      assert_equal ['inv-1'], @sent
    end

    def test_retrying_looks_up_no_client_and_checks_no_iban
      with_platform(send_outcome: true) { @adapter.submit(@sale, remote_id: 'inv-1') }

      refute @client_resolved, 'the client was resolved the first time'
      refute @iban_checked, 'the local prerequisites were checked the first time'
    end

    def test_a_retry_finding_the_invoice_already_sent_is_a_success_not_a_failure
      # The first attempt did go through but its answer was lost: nothing is sent again.
      result = with_platform(send_outcome: NOT_IN_DRAFT) { @adapter.submit(@sale, remote_id: 'inv-1') }

      assert result.ok?
      assert_equal 'inv-1', result.value
      assert_empty @created
    end

    def test_a_retry_failing_for_another_reason_stays_a_failure
      result = with_platform(send_outcome: NOT_REACHABLE) { @adapter.submit(@sale, remote_id: 'inv-1') }

      refute result.ok?
      assert_equal 'recipient_not_reachable_on_einvoicing', result.error_code
    end

    def test_a_just_created_invoice_refused_as_not_a_draft_is_a_failure
      # Only a retry may read "not a draft" as "already out".
      result = with_platform(send_outcome: NOT_IN_DRAFT) { @adapter.submit(@sale) }

      refute result.ok?
      assert_equal 'invoice_not_in_draft_status', result.error_code
    end

    def test_a_failing_callback_does_not_stop_the_sending
      result = with_platform(send_outcome: true) { @adapter.submit(@sale, on_created: ->(_id) { raise 'database down' }) }

      assert result.ok?
      assert_equal ['inv-1'], @sent
    end

    def test_a_creation_that_returns_no_id_is_a_failure_and_sends_nothing
      result = with_platform(create_body: { client_invoice: {} }, send_outcome: true) { @adapter.submit(@sale) }

      refute result.ok?
      assert_equal 'create_failed', result.error_code
      assert_empty @sent
    end

    private

      # Replaces the integration calls and the local lookups: nothing leaves the process.
      def with_platform(send_outcome:, create_body: { client_invoice: { id: 'inv-1' } })
        created = @created
        sent = @sent
        create = lambda do |payload|
          created << payload
          FakeCall.new(create_body, true)
        end
        send_call = lambda do |id|
          sent << id
          send_outcome == true ? FakeCall.new(true, true) : FakeCall.new(send_outcome, false)
        end

        resolve = lambda do |_entity|
          @client_resolved = true
          'cli-1'
        end
        iban = lambda do
          @iban_checked = true
          'FR7600000000000000000000000'
        end

        @adapter.stub(:resolve_client_id, resolve) do
          @adapter.stub(:organization_iban, iban) do
            ::Qonto::ClientInvoicePayload.stub(:build, { payload: true }) do
              ::Qonto::QontoIntegration.stub(:create_client_invoice, create) do
                ::Qonto::QontoIntegration.stub(:send_client_invoice, send_call) { yield }
              end
            end
          end
        end
      end
  end
end
