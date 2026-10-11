# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_payloads'

class Qonto::EInvoiceXmlParserTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoPayloads

  def test_reads_ubl_header_and_supplier
    parsed = Qonto::EInvoiceXmlParser.call(ubl_invoice_xml)

    assert_equal :ubl, parsed[:format]
    assert_equal 'FA-2026-0042', parsed[:number]
    assert_equal Date.new(2026, 9, 30), parsed[:issued_on]
    assert_equal Date.new(2026, 10, 30), parsed[:due_on]
    assert_equal 'EUR', parsed[:currency]
    refute parsed[:credit_note]
    assert_equal '144.0', parsed[:amount]
    assert_equal '120.0', parsed[:pretax_amount]
    assert_equal '24.0', parsed[:tax_amount]
    # SIRET (scheme 0009) is preferred to the SIREN of the legal entity.
    assert_equal({ name: 'Ferme Exemple SARL', tax_id: SIRET, vat_number: VAT }, parsed[:supplier])
  end

  def test_reads_ubl_lines
    lines = Qonto::EInvoiceXmlParser.call(ubl_invoice_xml)[:lines]

    assert_equal 2, lines.size
    first = lines.first
    assert_equal 'Semences de blé', first[:label]
    assert_equal 'Lot 7', first[:description]
    assert_equal '10.0', first[:quantity]
    assert_equal 'KGM', first[:unit_code]
    assert_equal '10.0', first[:unit_pretax_amount]
    assert_equal '100.0', first[:total_pretax_amount]
    assert_equal '20.0', first[:vat_rate]
  end

  def test_unit_price_honours_base_quantity
    second = Qonto::EInvoiceXmlParser.call(ubl_invoice_xml)[:lines].last

    # 100 € per 10 units → 10 € each, and 2 × 10 = the 20 € of the line.
    assert_equal '10.0', second[:unit_pretax_amount]
    assert_equal '20.0', second[:total_pretax_amount]
    assert_nil second[:description], 'no description when the item has none'
  end

  def test_lines_add_up_to_the_pretax_total
    parsed = Qonto::EInvoiceXmlParser.call(ubl_invoice_xml)
    total = parsed[:lines].sum { |l| BigDecimal(l[:total_pretax_amount]) }

    assert_equal BigDecimal(parsed[:pretax_amount]), total
  end

  def test_reads_cii
    parsed = Qonto::EInvoiceXmlParser.call(cii_invoice_xml)

    assert_equal :cii, parsed[:format]
    assert_equal 'FA-CII-1', parsed[:number]
    assert_equal Date.new(2026, 9, 30), parsed[:issued_on]
    assert_equal Date.new(2026, 10, 30), parsed[:due_on]
    assert_equal '360.0', parsed[:amount]
    assert_equal '300.0', parsed[:pretax_amount]
    assert_equal({ name: 'Coop Exemple', tax_id: SIRET, vat_number: VAT }, parsed[:supplier])

    line = parsed[:lines].first
    assert_equal 'Gazole non routier', line[:label]
    assert_equal '200.0', line[:quantity]
    assert_equal 'LTR', line[:unit_code]
    assert_equal '1.5', line[:unit_pretax_amount]
    assert_equal '20.0', line[:vat_rate]
  end

  def test_derives_a_missing_unit_price_from_the_line_total
    xml = ubl_invoice_xml.sub(%r{<cac:Price>\s*<cbc:PriceAmount currencyID="EUR">10.00</cbc:PriceAmount>\s*</cac:Price>}, '')

    assert_equal '10.0', Qonto::EInvoiceXmlParser.call(xml)[:lines].first[:unit_pretax_amount]
  end

  def test_flags_a_credit_note
    xml = ubl_invoice_xml.sub('<cbc:InvoiceTypeCode>380<', '<cbc:InvoiceTypeCode>381<')

    assert Qonto::EInvoiceXmlParser.call(xml)[:credit_note]
  end

  def test_returns_nil_for_anything_that_is_not_an_invoice
    assert_nil Qonto::EInvoiceXmlParser.call(nil)
    assert_nil Qonto::EInvoiceXmlParser.call('')
    assert_nil Qonto::EInvoiceXmlParser.call('<not-closed>')
    assert_nil Qonto::EInvoiceXmlParser.call('<html><body>nope</body></html>')
    assert_nil Qonto::EInvoiceXmlParser.call('%PDF-1.4 binary')
  end

  def test_does_not_resolve_external_entities
    xml = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE Invoice [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
      <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
               xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
        <cbc:ID>&xxe;</cbc:ID>
      </Invoice>
    XML

    parsed = Qonto::EInvoiceXmlParser.call(xml)
    refute_includes parsed.to_s, 'root:', 'a local file must never end up in the invoice'
  end
end
