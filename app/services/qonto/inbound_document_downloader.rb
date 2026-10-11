# frozen_string_literal: true

require 'open-uri'

module Qonto
  # Downloads the PDF / Factur-X of a received supplier e-invoice into a
  # Document. Idempotent (keyed per Qonto remote id), so re-running the fetch
  # does not create duplicate documents.
  class InboundDocumentDownloader
    DOCUMENT_NATURE = 'purchases_invoice'

    # @param nature [String, nil] Document nature; purchases_invoice by default.
    #   Pass nil explicitly for a supporting document that is not an invoice
    #   (card receipt…), like the bank-line attachments the plugin already makes.
    def self.call(remote_id:, url:, name: nil, nature: DOCUMENT_NATURE)
      new(remote_id: remote_id, url: url, name: name, nature: nature).call
    end

    def initialize(remote_id:, url:, name: nil, nature: DOCUMENT_NATURE)
      @remote_id = remote_id
      @url = url
      @name = name
      @nature = nature
    end

    # @return [Document, nil] nil when there is no url to fetch
    def call
      return nil if @url.blank?

      existing = Document.where(key: key).first
      return existing if existing

      Document.create!(
        nature: @nature,
        key: key,
        name: @name.presence || "e-invoice-#{@remote_id}.pdf",
        file: URI.parse(@url).open
      )
    end

    private

      def key
        "qonto-einvoice-#{@remote_id}"
      end
  end
end
