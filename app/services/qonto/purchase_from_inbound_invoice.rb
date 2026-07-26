# frozen_string_literal: true

module Qonto
  # Turns a received supplier e-invoice into a PurchaseInvoice, pre-filled with
  # everything we can derive without human judgement (supplier, external
  # reference, invoice date, currency, attached PDF), and links the two so the
  # inbox never produces a silent duplicate.
  #
  # Structured lines are materialised as PurchaseItems only when the tenant has
  # opted in by configuring a fallback variant
  # (Preference[:qonto_default_purchase_variant_id]) — an e-invoice carries no
  # catalog reference, so a valid item needs a placeholder variant the
  # accountant re-maps. Without it, the purchase is created header-only.
  class PurchaseFromInboundInvoice
    DEFAULT_VARIANT_PREFERENCE = :qonto_default_purchase_variant_id

    class Error < StandardError; end

    def self.call(inbound)
      new(inbound).call
    end

    def initialize(inbound)
      @inbound = inbound
    end

    # @return [PurchaseInvoice]
    # @raise [Error] when the invoice cannot be turned into a purchase yet
    def call
      raise Error, 'supplier not identified' unless @inbound.entity
      return @inbound.purchase if @inbound.purchase # idempotent

      nature = PurchaseNature.by_default || PurchaseNature.first
      raise Error, 'no purchase nature configured' unless nature

      ApplicationRecord.transaction do
        purchase = PurchaseInvoice.create!(
          nature: nature,
          supplier: @inbound.entity,
          reference_number: @inbound.invoice_number,
          invoiced_at: writeable_invoiced_at,
          currency: @inbound.currency.presence || nature.currency
        )
        build_items(purchase)
        attach_document(purchase)
        @inbound.update!(status: 'matched', purchase: purchase)
        purchase
      end
    end

    private

      # Pre-maps the structured lines onto a placeholder variant. quantity,
      # unit price and tax come from the invoice; account/amounts are derived by
      # PurchaseItem. Skips silently (leaving the item off) when a line has no
      # unit price or no tax matches its VAT rate — never fabricates a tax.
      def build_items(purchase)
        variant = default_variant
        return if variant.nil?

        unit = variant.default_unit
        Array(@inbound.lines).each do |raw_line|
          line = raw_line.symbolize_keys
          unit_pretax = to_decimal(line[:unit_pretax_amount])
          next if unit_pretax.nil?

          tax = tax_for(line[:vat_rate])
          next if tax.nil?

          purchase.items.create!(
            variant: variant,
            tax: tax,
            conditioning_unit: unit,
            conditioning_quantity: to_decimal(line[:quantity]) || 1,
            unit_pretax_amount: unit_pretax,
            annotation: line[:label].presence
          )
        end
      end

      def default_variant
        # Custom preference: read the row directly (Preference[] only accepts
        # predefined preferences).
        id = Preference.find_by(name: DEFAULT_VARIANT_PREFERENCE.to_s)&.value
        id.present? ? ProductNatureVariant.find_by(id: id) : nil
      end

      def tax_for(rate)
        amount = to_decimal(rate)
        return nil if amount.nil?

        Tax.where(amount: amount).reorder(:id).first
      end

      def to_decimal(value)
        return nil if value.nil? || value.to_s.strip.empty?

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      # Prefer the supplier's invoice date, but only if it falls in an open
      # financial year; otherwise fall back to today (also only if open). nil
      # lets the model default to created_at and, if still not writeable, fail
      # loudly rather than booking into a closed period.
      def writeable_invoiced_at
        [@inbound.issued_on, Date.current].compact.find do |date|
          FinancialYear.on(date)&.opened?
        end&.to_time
      end

      def attach_document(purchase)
        return unless @inbound.document && purchase.respond_to?(:attachments)

        purchase.attachments.create!(document: @inbound.document)
      end
  end
end
