# frozen_string_literal: true

require 'openssl'

module Qonto
  # Qonto client-invoices webhook. Runs outside the authenticated backend (no
  # Devise, no CSRF) — the tenant is already selected by the Apartment elevator
  # from the subdomain. The webhook carries einvoicing_status but NOT the
  # lifecycle array, so it is only a re-fetch signal: verify HMAC, then enqueue a
  # RefreshEInvoiceJob.
  class WebhooksController < ActionController::Base
    skip_forgery_protection

    SIGNATURE_HEADER = 'X-Qonto-Signature'

    def client_invoices
      return head(:unauthorized) unless valid_signature?

      remote_id = extract_remote_id
      outbound = remote_id.present? ? Qonto::OutboundInvoice.find_by(remote_id: remote_id) : nil
      Qonto::RefreshEInvoiceJob.perform_later(outbound_id: outbound.id) if outbound

      head :ok
    end

    private

      def extract_remote_id
        body = parsed_body
        body.dig('client_invoice', 'id') || body['id'] || body.dig('data', 'id')
      end

      def parsed_body
        JSON.parse(request.raw_post)
      rescue JSON::ParserError
        {}
      end

      def valid_signature?
        secret = webhook_secret
        return false if secret.blank?

        provided = request.headers[SIGNATURE_HEADER].to_s
        expected = OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)
        provided.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
      end

      def webhook_secret
        Preference.get('qonto_webhook_secret')&.value.presence || ENV['QONTO_WEBHOOK_SECRET']
      end
  end
end
