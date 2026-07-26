# frozen_string_literal: true

module Qonto
  # Pulls supplier e-invoices from the Plateforme Agréée (via the gateway) and
  # upserts them into the reception inbox. Idempotent: safe to run on a
  # schedule and to re-run.
  class FetchInboundInvoicesJob < ActiveJob::Base
    queue_as :default

    # Whether the hourly scheduler should enqueue this job for the current
    # tenant: only when a Qonto integration is configured. Avoids enqueuing a
    # no-op (Null-adapter) job on every tenant every hour.
    def self.schedulable?
      EInvoicing::Gateway.available?
    end

    def perform(user_id: nil)
      # Keep the compliance banner (S1) fresh without a synchronous HTTP call in
      # any view render.
      Qonto::EInvoicingSettings.refresh!

      gateway = EInvoicing::Gateway.build
      invoices = gateway.inbound_since(last_sync_at)
      created = Qonto::InboundInvoicesImportService.call(invoices: invoices)
      notify(user_id, created)
      created
    rescue StandardError => error
      Rails.logger.error("[Qonto] inbound fetch failed: #{error.class}: #{error.message}")
      ExceptionNotifier.notify_exception(error) if defined?(ExceptionNotifier)
      raise
    end

    private

      # v1: full, idempotent pull. A future increment can turn this into an
      # incremental cursor (e.g. a Preference storing the last Qonto updated_at).
      def last_sync_at
        nil
      end

      def notify(user_id, created)
        return if user_id.blank? || created.to_i.zero?

        user = User.find_by(id: user_id)
        return unless user

        user.notifications.create!(
          message: :new_einvoices_received.tl,
          level: :info,
          target_url: '/qonto/inbound_invoices',
          interpolations: { count: created.to_s }
        )
      end
  end
end
