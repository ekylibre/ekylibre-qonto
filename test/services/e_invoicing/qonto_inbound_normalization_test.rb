# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_payloads'

# The adapter maps what GET /v2/supplier_invoices really returns. These tests
# use that real shape: the previous mapping was written on guessed field names
# and left the SIRET, the file, the pre-tax amount and the lines empty.
class EInvoicing::QontoInboundNormalizationTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoPayloads

  def normalize(raw)
    EInvoicing::Adapters::Qonto.new.send(:normalize_inbound, raw)
  end

  def test_maps_the_fields_qonto_really_sends
    n = normalize(supplier_invoice)

    assert_equal '0198a1b2-0000-7000-8000-000000000001', n[:remote_id]
    assert_equal 'invoice', n[:kind]
    assert_equal 'Ferme Exemple', n[:supplier_name]
    assert_equal SIRET, n[:supplier_siret]
    assert_equal VAT, n[:supplier_vat]
    assert_equal 'FA-100', n[:invoice_number]
    assert_equal 'EUR', n[:currency]
    assert_equal BigDecimal('120'), n[:amount]
    assert_equal Date.new(2026, 9, 30), n[:issued_on]
    assert_equal Date.new(2026, 10, 30), n[:due_on]
    assert_equal 'paid', n[:remote_status]
  end

  def test_pretax_is_derived_from_total_and_tax
    assert_equal BigDecimal('100'), normalize(supplier_invoice)[:pretax_amount]
  end

  def test_pretax_prefers_the_amount_excluding_taxes_object
    n = normalize(supplier_invoice(total_amount_excluding_taxes: { value: '99.5', currency: 'EUR' }))

    assert_equal BigDecimal('99.5'), n[:pretax_amount]
  end

  def test_pretax_is_nil_rather_than_guessed_when_the_tax_is_unknown
    n = normalize(supplier_invoice(total_tax_amount: nil, taxes: nil))

    assert_nil n[:pretax_amount]
  end

  def test_tax_id_keeps_digits_only_and_may_be_a_siren
    assert_equal SIREN, normalize(supplier_invoice(tin_number: '123 456 782'))[:supplier_siret]
  end

  def test_supplier_name_falls_back_on_the_other_name_fields
    assert_equal 'Ferme Exemple SARL', normalize(supplier_invoice(supplier_name: nil))[:supplier_name]
    assert_equal 'Snapshot SA', normalize(supplier_invoice(supplier_name: nil, issuer_name: nil, supplier_snapshot: { name: 'Snapshot SA' }))[:supplier_name]
    assert_equal 'Vendeur SA', normalize(supplier_invoice(supplier_name: nil, issuer_name: nil, seller: { name: 'Vendeur SA' }))[:supplier_name]
  end

  def test_kind_follows_the_attachment_category
    assert_equal 'expense', normalize(supplier_invoice(attachment_category: 'EXPENSE_RECEIPT'))[:kind]
    assert_equal 'receipt', normalize(supplier_invoice(attachment_category: 'CARD_RECEIPT'))[:kind]
    assert_equal 'other',   normalize(supplier_invoice(attachment_category: 'OTHER_FINANCIAL_DOCUMENT'))[:kind]
  end

  def test_the_file_is_referenced_by_attachment_ids_not_by_url
    n = normalize(supplier_invoice)

    assert_equal 'att-pdf-1', n[:display_attachment_id]
    refute n[:structured], 'same attachment for both: a plain PDF, no structured XML'
    refute n.key?(:file_url), 'the list never carries a URL'
  end

  def test_an_einvoice_has_a_structured_attachment_apart_from_the_displayed_pdf
    n = normalize(supplier_invoice(attachment_id: 'att-xml-1', display_attachment_id: 'att-pdf-1'))

    assert n[:structured]
    assert_equal 'att-xml-1', n[:attachment_id]
    assert_equal 'att-pdf-1', n[:display_attachment_id]
  end

  def test_a_bare_payload_degrades_to_nil_instead_of_raising
    n = normalize(id: 'bare-1')

    assert_equal 'bare-1', n[:remote_id]
    assert_equal 'other', n[:kind]
    [:supplier_name, :supplier_siret, :invoice_number, :amount, :pretax_amount, :issued_on, :due_on].each do |key|
      assert_nil n[key], key.to_s
    end
  end

  def test_flags_credit_notes
    assert normalize(supplier_invoice(is_credit_note: true))[:credit_note]
    refute normalize(supplier_invoice)[:credit_note]
  end

  def test_attachment_resolves_the_signed_url
    adapter = EInvoicing::Adapters::Qonto.new
    body = { attachment: { id: 'att-1', file_name: 'a.pdf', file_size: '1234', file_content_type: 'application/pdf', url: 'https://s3.test/a.pdf' } }

    info = adapter.stub(:execute_result, body) { adapter.attachment('att-1') }

    assert_equal({ url: 'https://s3.test/a.pdf', content_type: 'application/pdf', file_name: 'a.pdf', size: 1234 }, info)
  end

  def test_attachment_is_nil_on_an_error_body_or_a_blank_id
    adapter = EInvoicing::Adapters::Qonto.new

    assert_nil adapter.attachment(nil)
    assert_nil adapter.stub(:execute_result, { error: { code: 'not_found' } }) { adapter.attachment('att-x') }
  end
end
