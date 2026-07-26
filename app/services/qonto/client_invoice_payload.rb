# frozen_string_literal: true

module Qonto
  # Maps an Ekylibre Sale to the Qonto client_invoice payload
  # (POST /v2/client_invoices). Qonto is the Plateforme Agréée that produces the
  # compliant Factur-X, so we only hand it structured data.
  #
  # The API requires: client_id (the client must pre-exist — see ClientResolver
  # in the adapter), issue_date, due_date, currency, payment_methods.iban and
  # inline items. Items are line entries, never products (no product_id). Kept
  # tolerant (compact) so a missing optional field is dropped rather than raising.
  class ClientInvoicePayload
    # Qonto caps the item title at 40 characters.
    TITLE_MAX = 40

    def self.build(sale, client_id:, iban:)
      new(sale, client_id: client_id, iban: iban).to_h
    end

    def initialize(sale, client_id:, iban:)
      @sale = sale
      @client_id = client_id
      @iban = iban
    end

    def to_h
      {
        number: @sale.number,
        client_id: @client_id,
        issue_date: issue_date,
        due_date: due_date,
        currency: @sale.currency,
        payment_methods: payment_methods,
        items: items
      }.compact
    end

    private

      def payment_methods
        return nil if @iban.blank?

        { iban: @iban }
      end

      def items
        @sale.items.map do |item|
          {
            title: item.label.to_s[0, TITLE_MAX],
            quantity: item.quantity.to_f,
            unit_price: { value: item.unit_pretax_amount.to_f, currency: @sale.currency },
            vat_rate: vat_rate(item)
          }.compact
        end
      end

      # Ekylibre stores the VAT as a percentage (20.0); Qonto expects a decimal
      # rate (0.2 for 20%).
      def vat_rate(item)
        amount = item.tax&.amount
        return nil if amount.nil?

        (amount.to_d / 100).to_f
      end

      def issue_date
        date(@sale.invoiced_at) || Date.current.iso8601
      end

      def due_date
        date(@sale.expired_at) || issue_date
      end

      def date(value)
        value&.to_date&.iso8601
      end
  end
end
