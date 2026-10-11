# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_payloads'

# What the import does on top of the upsert: sort by kind, find the supplier
# (SIRET, SIREN, VAT), fetch the file, and read the lines of an e-invoice.
class Qonto::InboundInvoicesEnrichmentTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoPayloads
  include WebMock::API

  XML_URL = 'https://files.qonto.test/einvoice.xml'
  PDF_URL = 'https://files.qonto.test/einvoice.pdf'

  # Counts the attachment lookups so a re-import can be shown not to refetch.
  class CountingGateway < EInvoicing::Adapters::Fake
    attr_reader :lookups

    def attachment(id)
      (@lookups ||= []) << id.to_s
      super
    end
  end

  teardown { WebMock.reset! }

  setup do
    @supplier = entities(:entities_008) # siret_number 12369874500015
    @document = Document.create!(nature: 'purchases_invoice', key: 'k-enrich', name: 'n', processable_attachment: false)
    @download_calls = []
  end

  # -- sorting ---------------------------------------------------------------

  def test_stores_the_kind
    import(normalized(remote_id: 'k-1', kind: 'expense'), normalized(remote_id: 'k-2', kind: 'receipt'))

    assert_equal 'expense', Qonto::InboundInvoice.find_by(remote_id: 'k-1').kind
    assert_equal 'receipt', Qonto::InboundInvoice.find_by(remote_id: 'k-2').kind
  end

  def test_the_kind_does_not_change_once_a_purchase_was_made
    import(normalized(remote_id: 'k-3', kind: 'invoice'))
    Qonto::InboundInvoice.find_by(remote_id: 'k-3').update!(status: 'matched')

    import(normalized(remote_id: 'k-3', kind: 'expense'))
    assert_equal 'invoice', Qonto::InboundInvoice.find_by(remote_id: 'k-3').kind
  end

  def test_a_document_discarded_or_archived_on_qonto_starts_ignored
    import(normalized(remote_id: 's-1', remote_status: 'discarded'),
           normalized(remote_id: 's-2', remote_status: 'archived'),
           normalized(remote_id: 's-3', remote_status: 'paid'))

    assert_equal %w[ignored ignored to_review], %w[s-1 s-2 s-3].map { |id| Qonto::InboundInvoice.find_by(remote_id: id).status }
  end

  def test_a_manual_status_survives_a_reimport
    import(normalized(remote_id: 's-4', remote_status: 'paid'))
    Qonto::InboundInvoice.find_by(remote_id: 's-4').update!(status: 'ignored')

    import(normalized(remote_id: 's-4', remote_status: 'paid'))
    assert_equal 'ignored', Qonto::InboundInvoice.find_by(remote_id: 's-4').status
  end

  # -- supplier --------------------------------------------------------------

  def test_matches_the_supplier_by_siret
    import(normalized(remote_id: 'm-1', siret: '12369874500015'))

    assert_equal @supplier.id, Qonto::InboundInvoice.find_by(remote_id: 'm-1').entity_id
  end

  def test_matches_the_supplier_by_siren_when_unambiguous
    import(normalized(remote_id: 'm-2', siret: '123698745'))

    assert_equal @supplier.id, Qonto::InboundInvoice.find_by(remote_id: 'm-2').entity_id
  end

  def test_a_siren_shared_by_two_entities_is_left_to_the_accountant
    other = entities(:entities_009)
    other.update_columns(siret_number: '12369874500023') # another establishment, same SIREN

    import(normalized(remote_id: 'm-3', siret: '123698745'))
    assert_nil Qonto::InboundInvoice.find_by(remote_id: 'm-3').entity_id, 'ambiguous: no guess'

    import(normalized(remote_id: 'm-4', siret: '12369874500023'))
    assert_equal other.id, Qonto::InboundInvoice.find_by(remote_id: 'm-4').entity_id, 'a full SIRET is exact'
  end

  def test_matches_the_supplier_by_vat_number_when_there_is_no_tax_id
    @supplier.update_columns(vat_number: 'FR 12 345678901')

    import(normalized(remote_id: 'm-5', siret: nil, vat: 'fr12345678901'))
    assert_equal @supplier.id, Qonto::InboundInvoice.find_by(remote_id: 'm-5').entity_id
  end

  def test_garbage_tax_ids_match_nobody
    import(normalized(remote_id: 'm-6', siret: 'oooooooooooooo'), normalized(remote_id: 'm-7', siret: '12'))

    assert_nil Qonto::InboundInvoice.find_by(remote_id: 'm-6').entity_id
    assert_nil Qonto::InboundInvoice.find_by(remote_id: 'm-7').entity_id
  end

  # -- file ------------------------------------------------------------------

  def test_the_file_url_is_resolved_through_the_gateway_with_the_invoice_nature
    gateway = fake_gateway('att-pdf-1' => { url: PDF_URL, file_name: 'fa.pdf', content_type: 'application/pdf' })

    import(normalized(remote_id: 'f-1', display_attachment_id: 'att-pdf-1'), gateway: gateway)

    assert_equal [{ url: PDF_URL, nature: 'purchases_invoice', name: 'fa.pdf' }], @download_calls
    assert_equal @document.id, Qonto::InboundInvoice.find_by(remote_id: 'f-1').document_id
  end

  def test_a_card_receipt_file_is_not_given_a_purchase_nature
    gateway = fake_gateway('att-r' => { url: PDF_URL, file_name: 'r.pdf', content_type: 'application/pdf' })

    import(normalized(remote_id: 'f-2', kind: 'receipt', display_attachment_id: 'att-r'), gateway: gateway)

    assert_nil @download_calls.first[:nature]
  end

  def test_an_unresolvable_attachment_leaves_the_record_without_a_document
    import(normalized(remote_id: 'f-3', display_attachment_id: 'gone'), gateway: fake_gateway({}))

    record = Qonto::InboundInvoice.find_by(remote_id: 'f-3')
    assert_not_nil record
    assert_nil record.document_id
    assert_empty @download_calls
  end

  def test_the_file_is_not_looked_up_again_once_downloaded
    gateway = fake_gateway('att-pdf-1' => { url: PDF_URL, file_name: 'fa.pdf', content_type: 'application/pdf' })
    attrs = normalized(remote_id: 'f-4', display_attachment_id: 'att-pdf-1')

    import(attrs, gateway: gateway)
    import(attrs, gateway: gateway)

    assert_equal ['att-pdf-1'], gateway.lookups
  end

  # -- e-invoice lines -------------------------------------------------------

  def test_reads_the_lines_and_the_header_of_an_einvoice
    stub_request(:get, XML_URL).to_return(body: ubl_invoice_xml, status: 200)
    import(einvoice('e-1'), gateway: einvoice_gateway)

    record = Qonto::InboundInvoice.find_by(remote_id: 'e-1')
    assert_equal 2, record.lines.size
    assert_equal ['Semences de blé', 'Transport'], record.line_items.map { |l| l[:label] }
    # The XML is the legal original: it wins over the platform's OCR values.
    assert_equal 'FA-2026-0042', record.invoice_number
    assert_equal SIRET, record.supplier_siret
    assert_equal BigDecimal('144'), record.amount
    assert_equal BigDecimal('120'), record.pretax_amount
    assert_equal Date.new(2026, 10, 30), record.due_on
  end

  def test_a_reimport_does_not_put_back_the_weaker_platform_values
    stub_request(:get, XML_URL).to_return(body: ubl_invoice_xml, status: 200)
    gateway = einvoice_gateway
    import(einvoice('e-2'), gateway: gateway)

    import(einvoice('e-2', invoice_number: 'OCR-WRONG', amount: 1), gateway: gateway)

    record = Qonto::InboundInvoice.find_by(remote_id: 'e-2')
    assert_equal 'FA-2026-0042', record.invoice_number
    assert_equal BigDecimal('144'), record.amount
    assert_equal 2, record.lines.size
    assert_equal 1, gateway.lookups.count('att-xml-1'), 'the XML is read once'
  end

  def test_the_supplier_is_found_from_the_xml_when_the_list_had_no_tax_id
    stub_request(:get, XML_URL).to_return(body: ubl_invoice_xml, status: 200)
    @supplier.update_columns(siret_number: SIRET)

    import(einvoice('e-3', siret: nil), gateway: einvoice_gateway)

    assert_equal @supplier.id, Qonto::InboundInvoice.find_by(remote_id: 'e-3').entity_id
  end

  def test_an_unreachable_xml_does_not_lose_the_invoice_and_is_retried_later
    stub_request(:get, XML_URL).to_timeout
    gateway = einvoice_gateway
    import(einvoice('e-4'), gateway: gateway)

    record = Qonto::InboundInvoice.find_by(remote_id: 'e-4')
    assert_not_nil record
    assert_empty record.lines

    stub_request(:get, XML_URL).to_return(body: ubl_invoice_xml, status: 200)
    import(einvoice('e-4'), gateway: gateway)
    assert_equal 2, record.reload.lines.size
  end

  def test_a_non_xml_attachment_is_never_parsed
    stub_request(:get, XML_URL).to_return(body: 'x', status: 200)
    gateway = fake_gateway('att-xml-1' => { url: XML_URL, content_type: 'application/pdf' },
                           'att-pdf-1' => { url: PDF_URL, file_name: 'a.pdf', content_type: 'application/pdf' })

    import(einvoice('e-5'), gateway: gateway)

    assert_empty Qonto::InboundInvoice.find_by(remote_id: 'e-5').lines
    WebMock.assert_not_requested(:get, XML_URL)
  end

  def test_a_plain_pdf_invoice_is_never_asked_for_a_structured_file
    gateway = fake_gateway('att-pdf-1' => { url: PDF_URL, file_name: 'a.pdf', content_type: 'application/pdf' })

    import(normalized(remote_id: 'e-6', attachment_id: 'att-pdf-1', display_attachment_id: 'att-pdf-1', structured: false), gateway: gateway)

    assert_equal ['att-pdf-1'], gateway.lookups, 'looked up once, for the displayed file only'
  end

  private

    # Ruby 2.6 would read a trailing invoice Hash as keywords, hence the splat.
    def import(*attrs)
      gateway = attrs.last.is_a?(Hash) && attrs.last.keys == [:gateway] ? attrs.pop[:gateway] : nil
      invoices = attrs
      stub = lambda do |remote_id:, url:, name:, nature:|
        @download_calls << { url: url, nature: nature, name: name }
        @document
      end
      Qonto::InboundDocumentDownloader.stub(:call, stub) do
        Qonto::InboundInvoicesImportService.call(invoices: invoices, gateway: gateway || fake_gateway({}))
      end
    end

    def fake_gateway(attachments)
      CountingGateway.new.stub_attachments(attachments)
    end

    def einvoice_gateway
      fake_gateway('att-xml-1' => { url: XML_URL, content_type: 'application/xml', file_name: 'e.xml' },
                   'att-pdf-1' => { url: PDF_URL, content_type: 'application/pdf', file_name: 'e.pdf' })
    end

    def einvoice(remote_id, overrides = {})
      normalized({ remote_id: remote_id, attachment_id: 'att-xml-1', display_attachment_id: 'att-pdf-1',
                   structured: true, siret: nil, invoice_number: 'OCR-1' }.merge(overrides))
    end

    # The shape EInvoicing::Adapters::Qonto#normalize_inbound produces.
    def normalized(overrides = {})
      o = { remote_id: 'x', kind: 'invoice', siret: nil, vat: nil, invoice_number: 'FA-1', amount: 120.0,
            remote_status: 'paid', attachment_id: nil, display_attachment_id: nil, structured: false }.merge(overrides)
      {
        remote_id: o[:remote_id], kind: o[:kind],
        supplier_name: 'Supplier', supplier_siret: o[:siret], supplier_vat: o[:vat],
        invoice_number: o[:invoice_number], currency: 'EUR', amount: o[:amount], pretax_amount: o[:amount],
        issued_on: Date.new(2026, 6, 1), due_on: Date.new(2026, 7, 1),
        remote_status: o[:remote_status], attachment_id: o[:attachment_id],
        display_attachment_id: o[:display_attachment_id], structured: o[:structured],
        lines: [], payload: { id: o[:remote_id] }
      }
    end
end
