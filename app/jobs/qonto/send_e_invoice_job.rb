# frozen_string_literal: true

module Qonto
  class SendEInvoiceJob < ActiveJob::Base
    queue_as :default

    def perform(sale_id:)
      sale = Sale.find(sale_id)
      outbound = Qonto::SendEInvoiceService.call(sale)
      # First poll right away so the lifecycle starts moving without waiting for
      # the hourly poll or a webhook.
      Qonto::RefreshEInvoiceJob.perform_later(outbound_id: outbound.id) if outbound.remote_id.present?
      outbound
    end
  end
end
