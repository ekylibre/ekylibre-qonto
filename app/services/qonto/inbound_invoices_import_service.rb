# frozen_string_literal: true

module Qonto
  # Upserts supplier e-invoices coming from the gateway into InboundInvoice
  # records, idempotently (keyed on remote_id), and pre-reconciles the supplier
  # by SIRET so the accountant lands on a mostly-filled inbox.
  class InboundInvoicesImportService
    def self.call(*args)
      new(*args).call
    end

    # @param invoices [Array<Hash>] normalized invoices from EInvoicing::Gateway#inbound_since
    def initialize(invoices:)
      @invoices = Array(invoices)
    end

    # @return [Integer] number of newly created records (excludes updates)
    def call
      created = 0
      @invoices.each do |attrs|
        next if attrs[:remote_id].blank?

        record = InboundInvoice.find_or_initialize_by(remote_id: attrs[:remote_id])
        created += 1 if record.new_record?
        apply_attributes(record, attrs)
        record.save!
        attach_document(record, attrs)
      end
      created
    end

    private

      # Downloads the PDF once (when absent), resiliently: a failed download
      # must not abort the whole import — the record stays and the document can
      # be fetched again on the next run (document_id remains nil).
      def attach_document(record, attrs)
        return if record.document_id.present? || attrs[:file_url].blank?

        document = Qonto::InboundDocumentDownloader.call(
          remote_id: record.remote_id, url: attrs[:file_url], name: attrs[:file_name]
        )
        record.update!(document: document) if document
      rescue StandardError => e
        Rails.logger.warn("[Qonto] inbound PDF download failed for #{record.remote_id}: #{e.class}: #{e.message}")
      end

      def apply_attributes(record, attrs)
        record.supplier_name  = attrs[:supplier_name]
        record.supplier_siret = attrs[:supplier_siret]
        record.invoice_number = attrs[:invoice_number]
        record.currency       = attrs[:currency]
        record.amount         = attrs[:amount]
        record.pretax_amount  = attrs[:pretax_amount]
        record.issued_on      = attrs[:issued_on]
        record.due_on         = attrs[:due_on]
        record.payload        = attrs[:payload] || {}
        record.lines          = attrs[:lines] || []
        # New records start "to_review"; never downgrade a manual status.
        record.status ||= 'to_review'
        # Pre-reconcile the supplier, without overwriting a manual match.
        record.entity ||= match_supplier(attrs[:supplier_siret])
      end

      def match_supplier(siret)
        return nil if siret.blank?

        Entity.where(siret_number: siret).first
      end
  end
end
