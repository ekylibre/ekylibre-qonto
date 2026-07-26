# frozen_string_literal: true

module Qonto
  # Hourly safety net: refresh every still-in-progress emission (the 204 does not
  # guarantee progress, and the webhook carries no lifecycle detail — it is only
  # a re-fetch signal). Idempotent.
  class PollEInvoicesJob < ActiveJob::Base
    queue_as :default

    def perform
      Qonto::OutboundInvoice.in_progress.where.not(remote_id: nil).find_each do |outbound|
        Qonto::RefreshEInvoiceService.call(outbound)
      rescue StandardError => e
        Rails.logger.warn("[Qonto] e-invoice poll failed for ##{outbound.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
