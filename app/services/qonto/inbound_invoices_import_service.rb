# frozen_string_literal: true

require 'open-uri'

module Qonto
  # Upserts supplier documents coming from the gateway into InboundInvoice
  # records, idempotently (keyed on remote_id), and prepares them so the
  # accountant lands on a mostly-filled inbox:
  #
  #   - the supplier is pre-reconciled (SIRET / SIREN, then VAT number);
  #   - the displayable file is downloaded into a Document;
  #   - for a real e-invoice, the structured XML is read: it gives the invoice
  #     lines, which the platform's list never carries, and it is the legal
  #     original, so what it says wins over the platform's own extraction.
  class InboundInvoicesImportService
    # Qonto statuses meaning the user already put the document aside there.
    DISCARDED_REMOTE_STATUSES = %w[discarded archived].freeze
    # A structured invoice is a few KB; this only guards against a bogus link.
    MAX_XML_BYTES = 5_000_000

    def self.call(*args)
      new(*args).call
    end

    # @param invoices [Array<Hash>] normalized invoices from EInvoicing::Gateway#inbound_since
    # @param gateway [EInvoicing::Gateway, nil] resolves attachments; built on demand
    def initialize(invoices:, gateway: nil)
      @invoices = Array(invoices)
      @gateway = gateway
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
        read_structured_data(record, attrs)
      end
      created
    end

    private

      def gateway
        @gateway ||= EInvoicing::Gateway.build
      end

      # Downloads the displayable file once (when absent), resiliently: a failed
      # download must not abort the whole import — the record stays and the
      # document is fetched again on the next run (document_id remains nil).
      def attach_document(record, attrs)
        return if record.document_id.present?

        info = attrs[:file_url].present? ? { url: attrs[:file_url], file_name: attrs[:file_name] } : attachment_info(attrs[:display_attachment_id])
        return if info.nil? || info[:url].blank?

        document = Qonto::InboundDocumentDownloader.call(
          remote_id: record.remote_id, url: info[:url], name: info[:file_name] || attrs[:file_name],
          # A card receipt is not an invoice: no purchase nature on its file.
          nature: record.purchasable? ? Qonto::InboundDocumentDownloader::DOCUMENT_NATURE : nil
        )
        record.update!(document: document) if document
      rescue StandardError => e
        Rails.logger.warn("[Qonto] inbound document download failed for #{record.remote_id}: #{e.class}: #{e.message}")
      end

      # Reads the structured XML of an e-invoice (only those have one) and keeps
      # what it carries. Tried again on the next run while no line was read.
      def read_structured_data(record, attrs)
        return unless attrs[:structured] && record.lines.blank?

        info = attachment_info(attrs[:attachment_id])
        return if info.nil? || info[:url].blank?
        return unless info[:content_type].to_s.include?('xml')

        parsed = Qonto::EInvoiceXmlParser.call(download_text(info[:url]))
        return if parsed.nil?

        apply_structured(record, parsed, attrs)
        record.save!
      rescue StandardError => e
        Rails.logger.warn("[Qonto] structured e-invoice read failed for #{record.remote_id}: #{e.class}: #{e.message}")
      end

      def attachment_info(id)
        id.present? ? gateway.attachment(id) : nil
      end

      def download_text(url)
        URI.parse(url).open.read(MAX_XML_BYTES)
      end

      def apply_structured(record, parsed, attrs)
        supplier = parsed[:supplier] || {}
        record.lines          = parsed[:lines]
        record.supplier_name  = supplier[:name] if supplier[:name].present?
        record.supplier_siret = supplier[:tax_id] if supplier[:tax_id].present?
        record.invoice_number = parsed[:number] if parsed[:number].present?
        record.currency       = parsed[:currency] if parsed[:currency].present?
        record.issued_on      = parsed[:issued_on] if parsed[:issued_on]
        record.due_on         = parsed[:due_on] if parsed[:due_on]
        record.amount         = BigDecimal(parsed[:amount]) if parsed[:amount].present?
        record.pretax_amount  = BigDecimal(parsed[:pretax_amount]) if parsed[:pretax_amount].present?
        record.entity ||= match_supplier(record.supplier_siret, supplier[:vat_number] || attrs[:supplier_vat])
      end

      # A structured invoice already read keeps its XML header on re-import: the
      # platform's list would only put back its weaker, OCR-based values.
      def apply_attributes(record, attrs)
        xml_read = record.persisted? && attrs[:structured] && record.lines.present?

        unless xml_read
          record.supplier_name  = attrs[:supplier_name]
          record.supplier_siret = attrs[:supplier_siret]
          record.invoice_number = attrs[:invoice_number]
          record.currency       = attrs[:currency]
          record.amount         = attrs[:amount]
          record.pretax_amount  = attrs[:pretax_amount]
          record.issued_on      = attrs[:issued_on]
          record.due_on         = attrs[:due_on]
          record.lines          = attrs[:lines] if attrs[:lines].present?
        end
        record.payload = attrs[:payload] || {}
        # Once a purchase exists the document stays what it was made into.
        record.kind = attrs[:kind] if attrs[:kind].present? && !record.matched?
        # A document the user already discarded or archived on Qonto starts
        # ignored; never touch the status afterwards (manual choices win).
        record.status = 'ignored' if record.new_record? && DISCARDED_REMOTE_STATUSES.include?(attrs[:remote_status].to_s)
        # Pre-reconcile the supplier, without overwriting a manual match.
        record.entity ||= match_supplier(record.supplier_siret, attrs[:supplier_vat])
      end

      # SIRET (14 digits) is exact. SIREN (9) designates the company, so it
      # matches an entity only when that is unambiguous: several entities
      # sharing a SIREN (one per establishment) are left for the accountant.
      def match_supplier(tax_id, vat_number = nil)
        match_by_tax_id(tax_id) || match_by_vat(vat_number)
      end

      def match_by_tax_id(tax_id)
        id = tax_id.to_s.gsub(/\D/, '')
        scope = Entity.where.not(siret_number: [nil, ''])
        case id.size
        when 14 then unique(scope.where("REPLACE(siret_number, ' ', '') = ?", id))
        when 9  then unique(scope.where("REPLACE(siret_number, ' ', '') LIKE ?", "#{id}%"))
        end
      end

      def match_by_vat(vat_number)
        vat = vat_number.to_s.delete(' ').upcase
        return nil if vat.blank?

        unique(Entity.where.not(vat_number: [nil, '']).where("UPPER(REPLACE(vat_number, ' ', '')) = ?", vat))
      end

      def unique(scope)
        found = scope.limit(2).to_a
        found.one? ? found.first : nil
      end
  end
end
