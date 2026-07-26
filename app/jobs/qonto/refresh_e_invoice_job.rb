# frozen_string_literal: true

module Qonto
  class RefreshEInvoiceJob < ActiveJob::Base
    queue_as :default

    def perform(outbound_id:)
      outbound = Qonto::OutboundInvoice.find_by(id: outbound_id)
      return if outbound.nil?

      Qonto::RefreshEInvoiceService.call(outbound)
    end
  end
end
