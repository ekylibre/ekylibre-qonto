# frozen_string_literal: true

module Qonto
  # Submits a Sale to the PA for electronic emission and records the outcome on
  # its OutboundInvoice. A 204 from the PA means "accepted for processing", not
  # "sent": the status becomes `submitted`, never `received` — the lifecycle
  # poll/webhook drives it forward.
  #
  # Sending the same sale twice would put two invoices in front of the client,
  # so three things guard it:
  #   - one worker at a time: the sending is claimed under a row lock, and a
  #     second job (double click) finds it taken and returns;
  #   - no second draft: the platform's invoice id is recorded the moment it is
  #     created, and a retry after a failed sending only sends that one;
  #   - no stuck state: a worker that dies mid-sending releases the claim after
  #     OutboundInvoice::SUBMITTING_STALE_AFTER.
  class SendEInvoiceService
    def self.call(sale)
      new(sale).call
    end

    def initialize(sale)
      @sale = sale
    end

    # @return [OutboundInvoice]
    def call
      outbound = find_or_create_outbound
      return outbound unless claim(outbound)

      begin
        result = EInvoicing::Gateway.build.submit(
          @sale,
          remote_id: outbound.remote_id.presence,
          on_created: ->(remote_id) { outbound.update_columns(remote_id: remote_id) }
        )
        record(outbound, result)
      rescue StandardError => e
        # Whatever happens, never leave it "submitting": the user could not retry.
        fail!(outbound, 'exception', "#{e.class}: #{e.message}")
        raise
      end
      outbound
    end

    private

      # Two jobs may both try to create the row; the unique index lets one win.
      def find_or_create_outbound
        OutboundInvoice.find_or_create_by!(sale: @sale)
      rescue ActiveRecord::RecordNotUnique
        OutboundInvoice.find_by!(sale: @sale)
      end

      # @return [Boolean] whether this worker now holds the sending
      def claim(outbound)
        claimed = false
        outbound.with_lock do
          if outbound.claimable?
            outbound.update!(status: 'submitting')
            claimed = true
          end
        end
        claimed
      end

      def record(outbound, result)
        if result.ok?
          outbound.update!(status: 'submitted', remote_id: result.value,
                           submitted_at: Time.zone.now, last_error: {})
        else
          fail!(outbound, result.error_code, result.error_detail)
        end
      end

      def fail!(outbound, code, detail)
        outbound.update!(status: 'failed',
                         last_error: { 'code' => code.to_s, 'detail' => detail.to_s, 'at' => Time.zone.now })
      end
  end
end
