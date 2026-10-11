# frozen_string_literal: true

# Test data shaped like what Qonto really returns. Field names come from
# GET /v2/supplier_invoices checked against a live account (October 2026);
# names, identifiers and amounts are invented.
module QontoPayloads
  SIRET = '12345678200019'
  SIREN = '123456782'
  VAT = 'FR12123456782'

  # One element of GET /v2/supplier_invoices → supplier_invoices[].
  def supplier_invoice(overrides = {})
    {
      id: '0198a1b2-0000-7000-8000-000000000001',
      organization_id: '0198a1b2-0000-7000-8000-0000000000aa',
      status: 'paid',
      source_type: 'direct_upload',
      invoice_number: 'FA-100',
      description: 'Semences',
      total_amount: { value: '120.0', currency: 'EUR' },
      payable_amount: { value: '120.0', currency: 'EUR' },
      total_tax_amount: { value: '20.0', currency: 'EUR' },
      taxes: [{ tax_amount: { value: '20.0', currency: 'EUR' }, tax_rate: '20' }],
      attachment_id: 'att-pdf-1',
      display_attachment_id: 'att-pdf-1',
      file_name: 'fa-100.pdf',
      attachment_category: 'INVOICE',
      is_attachment_invoice: false,
      is_einvoice: true,
      is_credit_note: false,
      supplier_id: 'sup-1',
      supplier_name: 'Ferme Exemple',
      issuer_name: 'Ferme Exemple SARL',
      tin_number: SIRET,
      vat_number: VAT,
      issue_date: '2026-09-30',
      due_date: '2026-10-30',
      matched_transactions: [
        { subject_id: 'inv-1', subject_type: 'transaction', transaction_id: 'tx-uuid-1' },
        { subject_id: 'inv-1', subject_type: 'transfer', transaction_id: 'transfer-uuid-1' }
      ]
    }.merge(overrides)
  end

  # UBL 2.1 (Peppol BIS 3), the syntax Qonto delivers. Two lines: the second
  # prices 10 units per 100 € (BaseQuantity), i.e. 10 € each.
  def ubl_invoice_xml(number: 'FA-2026-0042')
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
               xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
               xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
        <cbc:CustomizationID>urn:cen.eu:en16931:2017</cbc:CustomizationID>
        <cbc:ID>#{number}</cbc:ID>
        <cbc:IssueDate>2026-09-30</cbc:IssueDate>
        <cbc:DueDate>2026-10-30</cbc:DueDate>
        <cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>
        <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
        <cac:AccountingSupplierParty>
          <cac:Party>
            <cbc:EndpointID schemeID="0225">#{SIREN}</cbc:EndpointID>
            <cac:PartyIdentification><cbc:ID schemeID="0009">#{SIRET}</cbc:ID></cac:PartyIdentification>
            <cac:PartyName><cbc:Name>Ferme Exemple</cbc:Name></cac:PartyName>
            <cac:PartyTaxScheme>
              <cbc:CompanyID>#{VAT}</cbc:CompanyID>
              <cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>
            </cac:PartyTaxScheme>
            <cac:PartyLegalEntity>
              <cbc:RegistrationName>Ferme Exemple SARL</cbc:RegistrationName>
              <cbc:CompanyID schemeID="0002">#{SIREN}</cbc:CompanyID>
            </cac:PartyLegalEntity>
          </cac:Party>
        </cac:AccountingSupplierParty>
        <cac:TaxTotal><cbc:TaxAmount currencyID="EUR">24.00</cbc:TaxAmount></cac:TaxTotal>
        <cac:LegalMonetaryTotal>
          <cbc:LineExtensionAmount currencyID="EUR">120.00</cbc:LineExtensionAmount>
          <cbc:TaxExclusiveAmount currencyID="EUR">120.00</cbc:TaxExclusiveAmount>
          <cbc:TaxInclusiveAmount currencyID="EUR">144.00</cbc:TaxInclusiveAmount>
          <cbc:PayableAmount currencyID="EUR">144.00</cbc:PayableAmount>
        </cac:LegalMonetaryTotal>
        <cac:InvoiceLine>
          <cbc:ID>1</cbc:ID>
          <cbc:InvoicedQuantity unitCode="KGM">10</cbc:InvoicedQuantity>
          <cbc:LineExtensionAmount currencyID="EUR">100.00</cbc:LineExtensionAmount>
          <cac:Item>
            <cbc:Description>Lot 7</cbc:Description>
            <cbc:Name>Semences de blé</cbc:Name>
            <cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent></cac:ClassifiedTaxCategory>
          </cac:Item>
          <cac:Price><cbc:PriceAmount currencyID="EUR">10.00</cbc:PriceAmount></cac:Price>
        </cac:InvoiceLine>
        <cac:InvoiceLine>
          <cbc:ID>2</cbc:ID>
          <cbc:InvoicedQuantity unitCode="C62">2</cbc:InvoicedQuantity>
          <cbc:LineExtensionAmount currencyID="EUR">20.00</cbc:LineExtensionAmount>
          <cac:Item>
            <cbc:Name>Transport</cbc:Name>
            <cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent></cac:ClassifiedTaxCategory>
          </cac:Item>
          <cac:Price>
            <cbc:PriceAmount currencyID="EUR">100.00</cbc:PriceAmount>
            <cbc:BaseQuantity unitCode="C62">10</cbc:BaseQuantity>
          </cac:Price>
        </cac:InvoiceLine>
      </Invoice>
    XML
  end

  # CII (Factur-X): what another approved platform may deliver.
  def cii_invoice_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
                                xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
                                xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
        <rsm:ExchangedDocument>
          <ram:ID>FA-CII-1</ram:ID>
          <ram:TypeCode>380</ram:TypeCode>
          <ram:IssueDateTime><udt:DateTimeString format="102">20260930</udt:DateTimeString></ram:IssueDateTime>
        </rsm:ExchangedDocument>
        <rsm:SupplyChainTradeTransaction>
          <ram:IncludedSupplyChainTradeLineItem>
            <ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>
            <ram:SpecifiedTradeProduct><ram:Name>Gazole non routier</ram:Name></ram:SpecifiedTradeProduct>
            <ram:SpecifiedLineTradeAgreement>
              <ram:NetPriceProductTradePrice><ram:ChargeAmount>1.50</ram:ChargeAmount></ram:NetPriceProductTradePrice>
            </ram:SpecifiedLineTradeAgreement>
            <ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="LTR">200</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>
            <ram:SpecifiedLineTradeSettlement>
              <ram:ApplicableTradeTax><ram:TypeCode>VAT</ram:TypeCode><ram:RateApplicablePercent>20.00</ram:RateApplicablePercent></ram:ApplicableTradeTax>
              <ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>300.00</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation>
            </ram:SpecifiedLineTradeSettlement>
          </ram:IncludedSupplyChainTradeLineItem>
          <ram:ApplicableHeaderTradeAgreement>
            <ram:SellerTradeParty>
              <ram:Name>Coop Exemple</ram:Name>
              <ram:SpecifiedLegalOrganization><ram:ID schemeID="0002">#{SIRET}</ram:ID></ram:SpecifiedLegalOrganization>
              <ram:SpecifiedTaxRegistration><ram:ID schemeID="VA">#{VAT}</ram:ID></ram:SpecifiedTaxRegistration>
            </ram:SellerTradeParty>
          </ram:ApplicableHeaderTradeAgreement>
          <ram:ApplicableHeaderTradeSettlement>
            <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
            <ram:SpecifiedTradePaymentTerms>
              <ram:DueDateDateTime><udt:DateTimeString format="102">20261030</udt:DateTimeString></ram:DueDateDateTime>
            </ram:SpecifiedTradePaymentTerms>
            <ram:SpecifiedTradeSettlementHeaderMonetarySummation>
              <ram:TaxBasisTotalAmount>300.00</ram:TaxBasisTotalAmount>
              <ram:TaxTotalAmount currencyID="EUR">60.00</ram:TaxTotalAmount>
              <ram:GrandTotalAmount>360.00</ram:GrandTotalAmount>
            </ram:SpecifiedTradeSettlementHeaderMonetarySummation>
          </ram:ApplicableHeaderTradeSettlement>
        </rsm:SupplyChainTradeTransaction>
      </rsm:CrossIndustryInvoice>
    XML
  end
end
