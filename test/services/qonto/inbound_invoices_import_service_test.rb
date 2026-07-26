# frozen_string_literal: true

require 'test_helper'

class Qonto::InboundInvoicesImportServiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008) # siret_number 12369874500015
    @invoices = [
      normalized(remote_id: 'si-1', siret: @supplier.siret_number, number: 'FA-1', amount: 120.0),
      normalized(remote_id: 'si-2', siret: 'oooooooooooooo', number: 'FA-2', amount: 55.5)
    ]
  end

  def test_upsert_is_idempotent
    assert_difference 'Qonto::InboundInvoice.count', 2 do
      Qonto::InboundInvoicesImportService.call(invoices: @invoices)
    end
    assert_no_difference 'Qonto::InboundInvoice.count' do
      created = Qonto::InboundInvoicesImportService.call(invoices: @invoices)
      assert_equal 0, created
    end
  end

  def test_pre_reconciles_supplier_by_siret
    Qonto::InboundInvoicesImportService.call(invoices: @invoices)

    matched = Qonto::InboundInvoice.find_by(remote_id: 'si-1')
    assert_equal @supplier.id, matched.entity_id, 'supplier matched by SIRET'
    assert matched.supplier_known?

    unmatched = Qonto::InboundInvoice.find_by(remote_id: 'si-2')
    assert_nil unmatched.entity_id, 'unknown SIRET stays unmatched'
    assert unmatched.to_review?
  end

  def test_reimport_does_not_override_manual_status
    Qonto::InboundInvoicesImportService.call(invoices: @invoices)
    Qonto::InboundInvoice.find_by(remote_id: 'si-2').update!(status: 'ignored')

    Qonto::InboundInvoicesImportService.call(invoices: @invoices)
    assert_equal 'ignored', Qonto::InboundInvoice.find_by(remote_id: 'si-2').status
  end

  def test_attaches_downloaded_document_when_file_url_present
    document = Document.create!(nature: 'purchases_invoice', key: 'k-att', name: 'n', processable_attachment: false)
    invoices = [normalized(remote_id: 'doc-1', siret: nil, number: 'D-1', amount: 10).merge(file_url: 'https://files.qonto.test/d1.pdf', file_name: 'd1.pdf')]

    stub = ->(remote_id:, url:, name:) { document }
    Qonto::InboundDocumentDownloader.stub(:call, stub) do
      Qonto::InboundInvoicesImportService.call(invoices: invoices)
    end

    assert_equal document.id, Qonto::InboundInvoice.find_by(remote_id: 'doc-1').document_id
  end

  def test_does_not_download_without_file_url
    called = false
    stub = ->(**) { called = true; nil }
    Qonto::InboundDocumentDownloader.stub(:call, stub) do
      Qonto::InboundInvoicesImportService.call(invoices: @invoices) # no :file_url
    end
    refute called, 'downloader must not be called without a file_url'
  end

  def test_download_failure_is_resilient
    invoices = [normalized(remote_id: 'doc-err', siret: nil, number: 'E-1', amount: 5).merge(file_url: 'https://files.qonto.test/err.pdf')]
    boom = ->(**) { raise 'network down' }

    Qonto::InboundDocumentDownloader.stub(:call, boom) do
      assert_difference 'Qonto::InboundInvoice.count', 1 do
        Qonto::InboundInvoicesImportService.call(invoices: invoices)
      end
    end
    assert_nil Qonto::InboundInvoice.find_by(remote_id: 'doc-err').document_id
  end

  private

    def normalized(remote_id:, siret:, number:, amount:)
      {
        remote_id: remote_id,
        supplier_name: "Supplier #{number}",
        supplier_siret: siret,
        invoice_number: number,
        currency: 'EUR',
        amount: amount,
        pretax_amount: amount,
        issued_on: Date.new(2026, 6, 1),
        due_on: Date.new(2026, 7, 1),
        payload: { id: remote_id, raw: true }
      }
    end
end
