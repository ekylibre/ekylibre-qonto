# frozen_string_literal: true

module Qonto
  # Turns a received supplier e-invoice into a PurchaseInvoice, pre-filled with
  # everything we can derive without human judgement (supplier, external
  # reference, invoice date, currency, attached PDF), and links the two so the
  # inbox never produces a silent duplicate.
  #
  # Supplier invoices and expense reports end up in the same model but not the
  # same nature: expense reports get their own PurchaseNature, created on first
  # use from the default one (same journal). Card receipts and other documents
  # are not purchases at all — see Qonto::AttachToBankStatement.
  #
  # Structured lines are materialised as PurchaseItems only when the tenant has
  # opted in by configuring a fallback variant
  # (Preference[:qonto_default_purchase_variant_id]) — an e-invoice carries no
  # catalog reference, so a valid item needs a placeholder variant the
  # accountant re-maps. Without it, the purchase is created header-only.
  class PurchaseFromInboundInvoice
    DEFAULT_VARIANT_PREFERENCE = :qonto_default_purchase_variant_id

    class Error < StandardError; end

    # The same invoice number is already a purchase. Carries what was found so
    # the caller can offer to link it instead.
    class DuplicateError < Error
      attr_reader :match

      def initialize(match)
        @match = match
        super("a purchase with this reference already exists (#{match.purchase.number})")
      end
    end

    # @param force [Boolean] create even though a purchase with the same
    #   reference exists (the accountant confirmed it is another invoice)
    def self.call(inbound, force: false)
      new(inbound, force: force).call
    end

    def initialize(inbound, force: false)
      @inbound = inbound
      @force = force
    end

    # @return [PurchaseInvoice]
    # @raise [Error] when the invoice cannot be turned into a purchase yet
    # @raise [DuplicateError] when it already exists as a purchase
    def call
      # Under a row lock: two clicks (or two users) at once must end with one
      # purchase, the second finding the first's.
      @inbound.with_lock do
        return @inbound.purchase if @inbound.purchase # idempotent

        raise Error, 'this document is not a purchase' unless @inbound.purchasable?
        raise Error, 'credit notes are not supported yet' if credit_note?
        raise Error, 'this invoice was issued by your own company' if Qonto::OwnCompany.current.issued?(@inbound)
        raise Error, 'supplier not identified' unless @inbound.entity

        unless @force
          duplicate = Qonto::PurchaseDuplicates.for(@inbound)
          raise DuplicateError, duplicate if duplicate
        end

        nature = @inbound.expense? ? expense_nature : default_nature
        raise Error, 'no purchase nature configured' unless nature

        create_purchase(nature)
      end
    end

    private

      def create_purchase(nature)
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

      def default_nature
        Qonto::PurchaseDefaults.default_nature
      end

      # The nature is found by its name, in either supported language, so a
      # tenant that switched locale does not get a second one.
      def expense_nature
        Qonto::PurchaseDefaults.expense_nature || create_expense_nature
      end

      def create_expense_nature
        base = default_nature
        return nil unless base

        PurchaseNature.create!(name: :expense_report_nature.tl, journal: base.journal, active: true, by_default: false)
      end

      def credit_note?
        @inbound.payload.to_h.deep_stringify_keys['is_credit_note'] == true
      end

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
        Qonto::PurchaseDefaults.default_variant
      end

      def tax_for(rate)
        Qonto::PurchaseDefaults.tax_for(rate)
      end

      def to_decimal(value)
        Qonto::PurchaseDefaults.to_decimal(value)
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
