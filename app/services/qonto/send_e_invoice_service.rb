# frozen_string_literal: true

module Qonto
  # Submits a Sale to the PA for electronic emission and records the outcome on
  # its OutboundInvoice. A 204 from the PA means "accepted for processing", not
  # "sent": the status becomes `submitted`, never `received` — the lifecycle
  # poll/webhook drives it forward.
  class SendEInvoiceService
    def self.call(sale)
      new(sale).call
    end

    def initialize(sale)
      @sale = sale
    end

    # @return [OutboundInvoice]
    def call
      outbound = OutboundInvoice.find_or_create_by!(sale: @sale)
      # Only submit from a non-started or previously failed state (retry).
      return outbound unless outbound.status == 'pending' || outbound.failed?

      result = EInvoicing::Gateway.build.submit(@sale)
      if result.ok?
        outbound.update!(status: 'submitted', remote_id: result.value,
                         submitted_at: Time.zone.now, last_error: {})
      else
        outbound.update!(status: 'failed',
                         last_error: { 'code' => result.error_code.to_s,
                                       'detail' => result.error_detail.to_s,
                                       'at' => Time.zone.now })
      end
      outbound
    end
  end
end
