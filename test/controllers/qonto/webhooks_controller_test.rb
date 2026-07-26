# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require 'openssl'

module Qonto
  class WebhooksControllerTest < Ekylibre::Testing::ApplicationControllerTestCase::WithFixtures
    SECRET = 'whsec_test'

    setup do
      Preference.set!('qonto_webhook_secret', SECRET, :string)
    end

    test 'valid signature enqueues a refresh for the matching invoice' do
      outbound = Qonto::OutboundInvoice.create!(sale: sales(:sales_001), remote_id: 'ci-1', status: 'submitted')

      captured = nil
      Qonto::RefreshEInvoiceJob.stub(:perform_later, ->(**kw) { captured = kw }) do
        post_signed({ client_invoice: { id: 'ci-1' } }.to_json)
      end

      assert_response :ok
      assert_equal({ outbound_id: outbound.id }, captured)
    end

    test 'an invalid signature is rejected' do
      request.headers[Qonto::WebhooksController::SIGNATURE_HEADER] = 'wrong'
      post :client_invoices, body: { id: 'x' }.to_json

      assert_response :unauthorized
    end

    test 'an unknown remote id enqueues nothing' do
      called = false
      Qonto::RefreshEInvoiceJob.stub(:perform_later, ->(**) { called = true }) do
        post_signed({ client_invoice: { id: 'does-not-exist' } }.to_json)
      end

      assert_response :ok
      refute called
    end

    private

      def post_signed(body)
        signature = OpenSSL::HMAC.hexdigest('SHA256', SECRET, body)
        request.headers[Qonto::WebhooksController::SIGNATURE_HEADER] = signature
        post :client_invoices, body: body
      end
  end
end
