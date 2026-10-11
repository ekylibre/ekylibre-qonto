# frozen_string_literal: true

module Qonto
  # What a purchase from this supplier usually looks like: the nature and the
  # lines (article, unit, tax) of its latest purchase, scaled to the amount the
  # bank paid. The same supplier is rarely billed for another kind of thing, so
  # the previous purchase is the best guess for how to enter the next one.
  #
  #   one line      → one line for the whole total
  #   several lines → the same lines, in the proportions of the previous
  #                   purchase (the last one takes the rounding)
  #   Qonto gave the VAT split of the transaction (vat_details)
  #                 → one line per rate, with the article of the line of the
  #                   previous purchase that had that rate (else its first)
  class LastPurchaseTemplate
    Result = Struct.new(:purchase, :nature_id, :items, keyword_init: true)

    # @param supplier [Entity]
    # @param amount [BigDecimal] tax-included total to enter
    # @param vat_details [Array<Hash>, nil] [{rate:, amount:, amount_excluding_vat:}] from Qonto
    # @return [Result, nil] nil when the supplier has no earlier purchase
    def self.for(supplier, amount, vat_details: nil)
      purchase = PurchaseInvoice.where(supplier: supplier).order(invoiced_at: :desc, id: :desc).includes(items: :tax).first
      lines = purchase&.items.to_a.reject { |i| i.amount.to_d.zero? && i.unit_pretax_amount.to_d.zero? }
      return nil if purchase.nil? || lines.empty?

      items = from_vat_details(lines, vat_details) || scaled(lines, amount)
      Result.new(purchase: purchase, nature_id: purchase.nature_id, items: items)
    end

    def self.scaled(lines, amount)
      total = lines.sum { |i| i.amount.to_d }
      remaining = amount
      lines.each_with_index.map do |line, index|
        share = if lines.one? || total.zero? then amount / lines.size
                else (amount * line.amount.to_d / total).round(2)
                end
        share = remaining if index == lines.size - 1
        remaining -= share
        line_item(line, share)
      end
    end
    private_class_method :scaled

    def self.from_vat_details(lines, vat_details)
      rows = Array(vat_details).map { |r| r.to_h.symbolize_keys }.select { |r| r[:rate] && r[:amount_excluding_vat] }
      return nil if rows.empty?

      rows.map do |row|
        line = lines.find { |l| l.tax && l.tax.amount.to_d == row[:rate].to_d } || lines.first
        tax = Tax.where(amount: row[:rate].to_d).reorder(:id).first || line.tax
        pretax = row[:amount_excluding_vat].to_d
        total = (pretax + row[:amount].to_d).round(2)
        line_item(line, total).merge(tax_id: tax&.id, unit_pretax_amount: pretax)
      end
    end
    private_class_method :from_vat_details

    def self.line_item(line, total)
      rate = line.tax ? line.tax.amount.to_d : 0
      { variant_id: line.variant_id, conditioning_unit_id: line.conditioning_unit_id, conditioning_quantity: 1,
        tax_id: line.tax_id, unit_pretax_amount: (total / (1 + rate / 100)).round(2), amount: total }
    end
    private_class_method :line_item
  end
end
