# frozen_string_literal: true

module Qonto
  # Finds the purchase an inbound document has already been entered as. The same
  # invoice reaches Ekylibre by several roads (typed by hand, imported, sent by
  # the supplier through Qonto): turning each of them into a purchase would
  # count it twice.
  #
  # A match is the same invoice number (normalized) and either
  #   :same_supplier — the supplier is the one the inbox already identified; or
  #   :same_amount   — same total, supplier unknown or entered under another
  #                    entity (the same company often exists twice).
  # A number alone is not enough: "1" or "2026-001" is common to many suppliers.
  class PurchaseDuplicates
    Match = Struct.new(:purchase, :certainty, keyword_init: true)

    AMOUNT_TOLERANCE = BigDecimal('0.01')
    PURCHASE_REFERENCE_SQL = Reference.sql("COALESCE(NULLIF(purchases.reference_number, ''), purchases.number)")

    # @return [Match, nil]
    def self.for(inbound)
      for_all([inbound])[inbound.id]
    end

    # One query for a whole page.
    # @return [Hash{Integer => Match}] by inbound id; absent when no duplicate
    def self.for_all(inbounds)
      candidates = Array(inbounds).select { |i| i.purchase_id.nil? && Reference.normalize(i.invoice_number).present? }
      return {} if candidates.empty?

      refs = candidates.map { |i| Reference.normalize(i.invoice_number) }.uniq
      purchases = PurchaseInvoice.where("#{PURCHASE_REFERENCE_SQL} IN (?)", refs).to_a
      by_reference = purchases.group_by { |p| Reference.normalize(p.reference_number.presence || p.number) }

      candidates.each_with_object({}) do |inbound, found|
        match = best_match(inbound, by_reference[Reference.normalize(inbound.invoice_number)])
        found[inbound.id] = match if match
      end
    end

    def self.best_match(inbound, purchases)
      return nil if purchases.blank?

      same_supplier = inbound.entity_id && purchases.find { |p| p.supplier_id == inbound.entity_id }
      return Match.new(purchase: same_supplier, certainty: :same_supplier) if same_supplier

      same_amount = inbound.amount && purchases.find { |p| p.amount && (p.amount - inbound.amount).abs <= AMOUNT_TOLERANCE }
      same_amount ? Match.new(purchase: same_amount, certainty: :same_amount) : nil
    end
    private_class_method :best_match
  end
end
