# frozen_string_literal: true

require 'nokogiri'

module Qonto
  # Reads the structured part of a received e-invoice (the XML attached by the
  # supplier's platform) into the PA-agnostic shape used by the inbox.
  #
  # Two syntaxes are accepted, both defined by EN 16931:
  #   - UBL 2.1  (root Invoice / CreditNote)       — what Qonto delivers today
  #   - CII      (root CrossIndustryInvoice)       — Factur-X, other PAs
  #
  # The XML is the legal original of an e-invoice, so what it carries takes
  # precedence over what the platform extracted from a PDF.
  #
  #   Qonto::EInvoiceXmlParser.call(xml_string)
  #   # => { format: :ubl, number: 'FA-1', issued_on: Date, due_on: Date,
  #   #      currency: 'EUR', credit_note: false,
  #   #      supplier: { name:, tax_id:, vat_number: },
  #   #      amount: '120.0', pretax_amount: '100.0', tax_amount: '20.0',
  #   #      lines: [{ line_id:, label:, description:, quantity:, unit_code:,
  #   #                unit_pretax_amount:, total_pretax_amount:, vat_rate: }] }
  #
  # Returns nil when the document is not a recognised e-invoice. Amounts are
  # kept as decimal strings so they round-trip through jsonb untouched.
  class EInvoiceXmlParser
    CREDIT_NOTE_TYPE_CODE = '381'

    def self.call(xml)
      new(xml).call
    end

    def initialize(xml)
      @xml = xml.to_s
    end

    def call
      return nil if @xml.strip.empty?

      # nonet: never fetch anything over the network; no entity expansion.
      doc = Nokogiri::XML(@xml) { |config| config.strict.nonet }
      doc.remove_namespaces!
      root = doc.root
      return nil if root.nil?

      case root.name
      when 'Invoice', 'CreditNote' then parse_ubl(root)
      when 'CrossIndustryInvoice' then parse_cii(root)
      end
    rescue Nokogiri::XML::SyntaxError => e
      Rails.logger.warn("[Qonto] unreadable e-invoice XML: #{e.message}")
      nil
    end

    private

      # ---------------------------------------------------------------- UBL

      def parse_ubl(root)
        party = root.at_xpath('AccountingSupplierParty/Party')
        type_code = text(root, 'InvoiceTypeCode') || text(root, 'CreditNoteTypeCode')
        pretax = decimal(text(root, 'LegalMonetaryTotal/TaxExclusiveAmount'))
        total = decimal(text(root, 'LegalMonetaryTotal/TaxInclusiveAmount')) ||
                decimal(text(root, 'LegalMonetaryTotal/PayableAmount'))
        tax = decimal(text(root, 'TaxTotal/TaxAmount'))

        {
          format: :ubl,
          number: text(root, 'ID'),
          issued_on: iso_date(text(root, 'IssueDate')),
          due_on: iso_date(text(root, 'DueDate')),
          currency: text(root, 'DocumentCurrencyCode'),
          credit_note: root.name == 'CreditNote' || type_code == CREDIT_NOTE_TYPE_CODE,
          supplier: ubl_supplier(party),
          amount: dec_s(total),
          pretax_amount: dec_s(pretax),
          tax_amount: dec_s(tax),
          lines: root.xpath('InvoiceLine | CreditNoteLine').map { |line| ubl_line(line) }
        }
      end

      def ubl_supplier(party)
        return {} if party.nil?

        # SIRET (scheme 0009) is the most precise French identifier, then the
        # legal-entity id (SIREN or SIRET depending on the platform).
        siret = party.at_xpath("PartyIdentification/ID[@schemeID='0009']")&.text
        legal = text(party, 'PartyLegalEntity/CompanyID')
        {
          name: text(party, 'PartyLegalEntity/RegistrationName') || text(party, 'PartyName/Name'),
          tax_id: digits(siret.presence || legal),
          vat_number: text(party, 'PartyTaxScheme/CompanyID')
        }
      end

      def ubl_line(line)
        quantity_node = line.at_xpath('InvoicedQuantity | CreditedQuantity')
        quantity = decimal(quantity_node&.text)
        total = decimal(text(line, 'LineExtensionAmount'))
        price = decimal(text(line, 'Price/PriceAmount'))
        base = decimal(text(line, 'Price/BaseQuantity'))
        price /= base if price && base && !base.zero?

        build_line(
          line_id: text(line, 'ID'),
          label: text(line, 'Item/Name') || text(line, 'Item/Description'),
          description: text(line, 'Item/Description'),
          quantity: quantity,
          unit_code: quantity_node && quantity_node['unitCode'],
          unit_price: price,
          total: total,
          vat_rate: decimal(text(line, 'Item/ClassifiedTaxCategory/Percent'))
        )
      end

      # ---------------------------------------------------------------- CII

      def parse_cii(root)
        trade = root.at_xpath('SupplyChainTradeTransaction')
        return nil if trade.nil?

        settlement = trade.at_xpath('ApplicableHeaderTradeSettlement')
        summation = settlement&.at_xpath('SpecifiedTradeSettlementHeaderMonetarySummation')

        {
          format: :cii,
          number: text(root, 'ExchangedDocument/ID'),
          issued_on: cii_date(text(root, 'ExchangedDocument/IssueDateTime/DateTimeString')),
          due_on: cii_date(settlement && text(settlement, 'SpecifiedTradePaymentTerms/DueDateDateTime/DateTimeString')),
          currency: settlement && text(settlement, 'InvoiceCurrencyCode'),
          credit_note: text(root, 'ExchangedDocument/TypeCode') == CREDIT_NOTE_TYPE_CODE,
          supplier: cii_supplier(trade.at_xpath('ApplicableHeaderTradeAgreement/SellerTradeParty')),
          amount: dec_s(decimal(summation && text(summation, 'GrandTotalAmount'))),
          pretax_amount: dec_s(decimal(summation && text(summation, 'TaxBasisTotalAmount'))),
          tax_amount: dec_s(decimal(summation && text(summation, 'TaxTotalAmount'))),
          lines: trade.xpath('IncludedSupplyChainTradeLineItem').map { |line| cii_line(line) }
        }
      end

      def cii_supplier(party)
        return {} if party.nil?

        {
          name: text(party, 'Name'),
          tax_id: digits(text(party, 'SpecifiedLegalOrganization/ID')),
          vat_number: party.at_xpath("SpecifiedTaxRegistration/ID[@schemeID='VA']")&.text&.strip.presence
        }
      end

      def cii_line(line)
        quantity_node = line.at_xpath('SpecifiedLineTradeDelivery/BilledQuantity')
        price = decimal(text(line, 'SpecifiedLineTradeAgreement/NetPriceProductTradePrice/ChargeAmount'))
        base = decimal(text(line, 'SpecifiedLineTradeAgreement/NetPriceProductTradePrice/BasisQuantity'))
        price /= base if price && base && !base.zero?

        build_line(
          line_id: text(line, 'AssociatedDocumentLineDocument/LineID'),
          label: text(line, 'SpecifiedTradeProduct/Name'),
          description: text(line, 'SpecifiedTradeProduct/Description'),
          quantity: decimal(quantity_node&.text),
          unit_code: quantity_node && quantity_node['unitCode'],
          unit_price: price,
          total: decimal(text(line, 'SpecifiedLineTradeSettlement/SpecifiedTradeSettlementLineMonetarySummation/LineTotalAmount')),
          vat_rate: decimal(text(line, 'SpecifiedLineTradeSettlement/ApplicableTradeTax/RateApplicablePercent'))
        )
      end

      # ------------------------------------------------------------- helpers

      # Fills what the document leaves out when it can be derived without
      # guessing: a missing unit price is total / quantity, never invented.
      def build_line(line_id:, label:, description:, quantity:, unit_code:, unit_price:, total:, vat_rate:)
        unit_price ||= (total / quantity if total && quantity && !quantity.zero?)
        {
          line_id: line_id,
          label: label,
          description: description == label ? nil : description,
          quantity: dec_s(quantity),
          unit_code: unit_code,
          unit_pretax_amount: dec_s(unit_price),
          total_pretax_amount: dec_s(total),
          vat_rate: dec_s(vat_rate)
        }
      end

      def text(node, path)
        node.at_xpath(path)&.text&.strip.presence
      end

      def digits(value)
        value.to_s.gsub(/\D/, '').presence
      end

      def decimal(value)
        return nil if value.to_s.strip.empty?

        BigDecimal(value.to_s.strip)
      rescue ArgumentError
        nil
      end

      def dec_s(value)
        value&.to_s('F')
      end

      def iso_date(value)
        value && Date.iso8601(value)
      rescue ArgumentError
        nil
      end

      # CII dates: format 102 is YYYYMMDD.
      def cii_date(value)
        value && Date.strptime(value.to_s.strip, '%Y%m%d')
      rescue ArgumentError
        nil
      end
  end
end
