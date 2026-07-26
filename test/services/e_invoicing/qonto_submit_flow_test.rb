# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# End-to-end contract test of the corrected emission flow: the adapter must
# resolve (find-or-create) the Qonto client, create the client_invoice
# referencing its client_id, then request e-invoice sending. Uses recorded
# cassettes (method+uri matching) — no live call.
module EInvoicing
  class QontoSubmitFlowTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
    setup do
      VCR.use_cassette('check_organization') do
        Integration.create!(nature: 'qonto', parameters: { client_id: 'cid', client_secret: 'sec' })
      end
      @sale = sales(:sales_001)
    end

    def test_submit_creates_client_then_invoice_then_sends
      result = nil
      VCR.use_cassette('submit_einvoice_flow') do
        result = Adapters::Qonto.new.submit(@sale)
      end

      assert result.ok?, "submit should succeed, got: #{result.error_code} #{result.error_detail}"
      assert_equal 'inv-uuid-1', result.value
    end

    def test_submit_fails_cleanly_without_an_iban
      # No bank account carries an IBAN → the required payment_methods.iban is
      # unavailable, so emission must fail before any HTTP call.
      Cash.bank_accounts.update_all(iban: nil)

      result = Adapters::Qonto.new.submit(@sale)

      refute result.ok?
      assert_equal 'missing_iban', result.error_code
    end

    # --- Idempotency via the Entity provider link -------------------------------

    def test_creation_persists_the_qonto_client_link
      VCR.use_cassette('submit_einvoice_flow') do
        Adapters::Qonto.new.submit(@sale)
      end

      client = @sale.client.reload
      assert client.is_provided_by?(vendor: 'qonto', name: 'client')
      assert_equal 'cli-uuid-1', client.provider_id
    end

    def test_linked_client_is_reused_without_any_client_http
      # Pre-linked → resolution must not hit GET/POST /v2/clients at all; the
      # 'submit_einvoice_linked' cassette only records the invoice create + send,
      # so any client call would raise (no cassette match).
      @sale.client.update_columns(provider: { vendor: 'qonto', name: 'client', id: 'cli-existing' })

      result = nil
      VCR.use_cassette('submit_einvoice_linked') do
        result = Adapters::Qonto.new.submit(@sale)
      end

      assert result.ok?, "#{result.error_code} #{result.error_detail}"
      assert_equal 'inv-uuid-2', result.value
    end

    def test_does_not_clobber_another_vendors_provider
      # An entity owned by another importer keeps its provider; emission still
      # resolves over the network (full flow cassette) but never overwrites it.
      @sale.client.update_columns(provider: { vendor: 'socleo', name: 'client', data: { entity_code: 'X1' } })

      VCR.use_cassette('submit_einvoice_flow') do
        Adapters::Qonto.new.submit(@sale)
      end

      client = @sale.client.reload
      assert_equal 'socleo', client.provider_vendor
      assert_equal 'X1', client.provider_data[:entity_code]
    end
  end
end
