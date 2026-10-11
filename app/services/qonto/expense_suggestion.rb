# frozen_string_literal: true

module Qonto
  # What can be said about the purchase behind a bank line that has none yet.
  # A plain value: building it never writes anything, and the accountant
  # validates it in the usual "new purchase" form of the bank reconciliation.
  #
  #   source  :inbound_invoice   a supplier document Qonto matched to the line
  #           :existing_purchase a purchase already entered, still unpaid
  #           :supplier_model    the supplier is known (from past payments) and its
  #                              latest purchase gives the shape of this one
  #           :none              nothing usable
  #   confidence :high / :medium / :low
  #   items   [{ variant_id:, conditioning_unit_id:, conditioning_quantity:,
  #              tax_id:, unit_pretax_amount:, amount: }] — amount is the tax-included total
  #   warnings :own_company :credit_note :already_entered :amount_mismatch :no_supplier :no_nature
  #   provenance { field => :inbound | :qonto | ... } where each field came from
  class ExpenseSuggestion
    ATTRIBUTES = %i[
      item source confidence supplier nature_id invoiced_at reference_number description
      items document inbound existing warnings provenance supplier_how model_purchase
    ].freeze
    AMOUNT_TOLERANCE = BigDecimal('0.01')

    attr_reader(*ATTRIBUTES)

    def initialize(item:, source: :none, confidence: :low, supplier: nil, nature_id: nil, invoiced_at: nil,
                   reference_number: nil, description: nil, items: [], document: nil, inbound: nil, existing: nil,
                   warnings: [], provenance: {}, supplier_how: nil, model_purchase: nil)
      @item = item
      @source = source
      @confidence = confidence
      @supplier = supplier
      @nature_id = nature_id
      @invoiced_at = invoiced_at
      @reference_number = reference_number
      @description = description
      @items = items
      @document = document
      @inbound = inbound
      @existing = existing
      @warnings = warnings
      @provenance = provenance
      @supplier_how = supplier_how
      @model_purchase = model_purchase
    end

    def none?
      source == :none
    end

    # Money going out of the account on that bank line.
    def expected_amount
      item.debit.to_d
    end

    def items_total
      items.sum { |i| i[:amount].to_d }
    end

    def balanced?
      items.any? && (items_total - expected_amount).abs <= AMOUNT_TOLERANCE
    end

    # Enough to open the form with nothing left to type but a click.
    def ready?
      source == :inbound_invoice && supplier.present? && nature_id.present? && balanced? && (warnings & BLOCKING_WARNINGS).empty?
    end

    BLOCKING_WARNINGS = %i[own_company credit_note already_entered].freeze

    # A purchase can be created from it (and not only looked at).
    def creatable?
      %i[inbound_invoice supplier_model].include?(source) && nature_id.present? && (warnings & BLOCKING_WARNINGS).empty?
    end

    # Parameters of Backend::QuickPurchasesController#new.
    def form_params(redirect: nil)
      trade = { reference_number: reference_number, description: description, invoiced_at: invoiced_at&.to_date&.iso8601 }.compact
      trade[:items_attributes] = items.each_with_index.map { |i, index| [index.to_s, i.compact.transform_values { |v| format_value(v) }] }.to_h if items.any?
      params = { nature_id: nature_id, bank_statement_item_ids: [item.id], trade: trade }
      params[:affair] = { third_id: supplier.id } if supplier
      params[:redirect] = redirect if redirect
      params
    end

    private

      # A BigDecimal prints as 0.3817e2: the form wants plain digits.
      def format_value(value)
        value.is_a?(BigDecimal) ? value.to_s('F') : value.to_s
      end
  end
end
