# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::InboundDocumentDownloaderTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_returns_nil_without_url
    assert_nil Qonto::InboundDocumentDownloader.call(remote_id: 'x', url: nil)
    assert_nil Qonto::InboundDocumentDownloader.call(remote_id: 'x', url: '')
  end

  def test_is_idempotent_when_document_already_exists
    key = 'qonto-einvoice-dup'
    existing = Document.create!(nature: Qonto::InboundDocumentDownloader::DOCUMENT_NATURE,
                                key: key, name: 'already.pdf', processable_attachment: false)
    # No cassette needed: the existing document short-circuits before any HTTP.
    result = Qonto::InboundDocumentDownloader.call(remote_id: 'dup', url: 'https://files.qonto.test/whatever.pdf')
    assert_equal existing.id, result.id
  end

  def test_downloads_pdf_into_a_document
    document = nil
    VCR.use_cassette('download_einvoice_pdf') do
      assert_difference 'Document.count', 1 do
        document = Qonto::InboundDocumentDownloader.call(
          remote_id: 'dl-1', url: 'https://files.qonto.test/einvoice-dl-1.pdf', name: 'FA-DL-1.pdf'
        )
      end
    end
    assert_equal 'qonto-einvoice-dl-1', document.key
    assert_equal Qonto::InboundDocumentDownloader::DOCUMENT_NATURE, document.nature
    assert document.file_file_name.present?
  end
end
