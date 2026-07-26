# frozen_string_literal: true

require 'test_helper'

class Qonto::ClientInvoicePayloadTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  IBAN = 'FR7611111222223333333333391'

  setup do
    @sale = sales(:sales_001)
  end

  def test_references_client_id_and_omits_inline_client
    payload = build(client_id: 'cli-123')

    assert_equal 'cli-123', payload[:client_id]
    refute payload.key?(:client), 'the client must be referenced by id, never inlined'
  end

  def test_carries_the_required_top_level_fields
    payload = build

    assert payload[:issue_date].present?
    assert payload[:due_date].present?
    assert_equal @sale.currency, payload[:currency]
    assert_equal({ iban: IBAN }, payload[:payment_methods])
    assert payload[:items].any?
  end

  def test_due_date_maps_the_sale_expiration
    @sale.update_columns(expired_at: Time.zone.parse('2026-03-15 00:00:00'))

    assert_equal '2026-03-15', build[:due_date]
  end

  def test_payment_methods_dropped_without_iban
    payload = build(iban: nil)

    refute payload.key?(:payment_methods)
  end

  def test_item_title_is_capped_at_40_chars
    item = @sale.items.first
    item.update_columns(label: 'X' * 60)

    first = build(sale: Sale.find(@sale.id))[:items].first
    assert_equal 40, first[:title].length
  end

  def test_vat_rate_is_a_decimal_rate_not_a_percentage
    item = @sale.items.first
    assert item.tax.present?, 'fixture precondition: the item carries a tax'

    first = build[:items].first
    expected = (item.tax.amount.to_d / 100).to_f
    assert_equal expected, first[:vat_rate]
    assert first[:vat_rate] < 1, 'a 20% VAT must serialize as 0.2, not 20.0'
  end

  private

    def build(sale: @sale, client_id: 'cli-123', iban: IBAN)
      Qonto::ClientInvoicePayload.build(sale, client_id: client_id, iban: iban)
    end
end
