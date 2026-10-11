# frozen_string_literal: true

module Qonto
  # Looks, for each bank line that has no purchase yet, for what could create
  # one — most reliable first:
  #
  #   1. the supplier document Qonto itself matched to the transaction
  #      (payload.matched_transactions): supplier, number, date and lines;
  #   2. a purchase already entered but not paid (same supplier or same total):
  #      creating another would count the expense twice;
  #   3. the supplier found from what was done for the same label before, and
  #      the shape of its latest purchase (nature, article, tax).
  #
  # Pure: nothing is written. Build it once for a page of lines, so the
  # lookups are done once.
  class ExpenseSuggester
    WINDOW_DAYS = 60
    TOLERANCE = BigDecimal('0.01')

    # @param items [Array<BankStatementItem>]
    # @return [Hash{Integer => ExpenseSuggestion}] by bank statement item id
    def self.for_all(items)
      suggester = new(items)
      items.each_with_object({}) { |item, found| found[item.id] = suggester.suggest(item) }
    end

    def self.qonto_id(item)
      provider = (item.provider || {}).to_h
      provider[:id] || provider['id']
    end

    def initialize(items)
      @inbound_by_transaction = index_inbound
      @own_company = OwnCompany.current
      @purchase_duplicates = duplicates_for(items)
      @resolver = nil
    end

    def suggest(item)
      inbound = @inbound_by_transaction[self.class.qonto_id(item)]
      suggestion = from_inbound(item, inbound) if inbound
      suggestion || existing_purchase(item) || supplier_model(item) || ExpenseSuggestion.new(item: item)
    end

    private

      # Documents still to review, by the Qonto transaction they are matched to.
      # A few dozen rows in practice: read once.
      def index_inbound
        InboundInvoice.to_review.includes(:entity, :document).each_with_object({}) do |inbound, map|
          inbound.matched_transaction_ids.each { |id| map[id] ||= inbound }
        end
      end

      def duplicates_for(items)
        inbounds = items.map { |i| @inbound_by_transaction[self.class.qonto_id(i)] }.compact.uniq
        Qonto::PurchaseDuplicates.for_all(inbounds.select(&:purchasable?))
      end

      def from_inbound(item, inbound)
        # A receipt or another document justifies the line, it is not a purchase.
        return nil unless inbound.purchasable?

        warnings = []
        warnings << :own_company if @own_company.issued?(inbound)
        warnings << :credit_note if credit_note?(inbound)
        receipt = Qonto::ReceiptReader.read(inbound.document)
        supplier, supplier_how = inbound.entity ? [inbound.entity, :inbound] : resolved_supplier(item)
        supplier, supplier_how = [receipt_supplier(receipt), :receipt] if supplier.nil? && receipt_supplier(receipt)
        warnings << :no_supplier unless supplier
        nature = nature_for(inbound)
        warnings << :no_nature unless nature

        if (duplicate = @purchase_duplicates[inbound.id])
          return ExpenseSuggestion.new(
            item: item, source: :existing_purchase, confidence: :high, existing: duplicate.purchase, inbound: inbound,
            supplier: duplicate.purchase.supplier, warnings: [:already_entered], provenance: { existing: :inbound }
          )
        end

        # A document without lines says nothing of what was bought: the supplier's
        # previous purchase does.
        model = inbound.line_items.empty? && supplier ? model_for(supplier, item) : nil
        # What the document itself says of the VAT beats scaling an older purchase.
        split = inbound.line_items.empty? ? receipt&.vat_split_for(item.debit.to_d).to_a : []
        items = if split.any?
                  receipt_items(split, model)
                elsif model
                  model.items
                else
                  items_for(inbound, item.debit.to_d)
                end
        warnings << :receipt_amount_mismatch if receipt && receipt.total_candidates.any? && !receipt.total_matches?(item.debit)
        suggestion = ExpenseSuggestion.new(
          item: item, source: :inbound_invoice, confidence: confidence_for(inbound, warnings),
          supplier: supplier, supplier_how: supplier_how, nature_id: nature&.id, invoiced_at: invoiced_at(inbound, item, receipt),
          reference_number: inbound.invoice_number.presence || receipt&.number, description: inbound.supplier_name, items: items,
          document: inbound.document, inbound: inbound, warnings: warnings, model_purchase: model&.purchase,
          provenance: provenance_for(inbound).merge(model ? { items: :history } : {}).merge(supplier_how.in?([:inbound, :receipt]) || supplier.nil? ? {} : { supplier: :history })
                                             .merge(receipt_provenance(inbound, receipt, supplier_how, split))
        )
        suggestion.warnings << :amount_mismatch unless suggestion.balanced?
        suggestion
      end

      # The supplier named by the SIRET printed on the document, when exactly one
      # entity carries it.
      def receipt_supplier(receipt)
        return nil if receipt&.siret.blank?

        found = Entity.where(siret_number: receipt.siret).limit(2).to_a
        found.one? ? found.first : nil
      end

      # One line per VAT rate, as printed. The variant and unit come from the
      # supplier's previous purchase when there is one.
      def receipt_items(split, model)
        base = model&.items&.first.to_h
        variant = base[:variant_id] ? nil : Qonto::PurchaseDefaults.default_variant
        split.map do |line|
          tax = Qonto::PurchaseDefaults.tax_for(line[:rate])
          { variant_id: base[:variant_id] || variant&.id, conditioning_unit_id: base[:conditioning_unit_id] || variant&.default_unit&.id,
            conditioning_quantity: 1, tax_id: tax&.id, unit_pretax_amount: line[:pretax], amount: line[:total] }
        end
      end

      def receipt_provenance(inbound, receipt, supplier_how, split)
        return {} unless receipt

        found = {}
        found[:supplier] = :receipt if supplier_how == :receipt
        found[:invoiced_at] = :receipt if inbound.issued_on.nil? && receipt.date
        found[:reference_number] = :receipt if inbound.invoice_number.blank? && receipt.number
        found[:items] = :receipt if split.any?
        found
      end

      def credit_note?(inbound)
        inbound.payload.to_h.deep_stringify_keys['is_credit_note'] == true
      end

      def nature_for(inbound)
        inbound.expense? ? (Qonto::PurchaseDefaults.expense_nature || Qonto::PurchaseDefaults.default_nature) : Qonto::PurchaseDefaults.default_nature
      end

      def confidence_for(inbound, warnings)
        return :low if warnings.any?

        inbound.lines.present? ? :high : :medium
      end

      def provenance_for(inbound)
        { supplier: inbound.entity ? :inbound : nil, reference_number: :inbound, invoiced_at: :inbound,
          items: inbound.lines.present? ? :inbound : :qonto }.compact
      end

      # The supplier's date when an exercise is open on it, else the day the
      # money left: the form would refuse a closed period.
      def invoiced_at(inbound, item, receipt = nil)
        [inbound.issued_on || receipt&.date_on, item.transfered_on].compact.find { |date| FinancialYear.on(date)&.opened? } || item.transfered_on
      end

      # Structured lines when the document has them, otherwise one line at the
      # document's VAT rate. Either way the total is what the bank paid when
      # the document is the whole payment.
      def items_for(inbound, debit)
        lines = inbound.line_items
        lines.any? ? lines_items(lines) : [header_item(inbound, debit)]
      end

      def lines_items(lines)
        variant = Qonto::PurchaseDefaults.default_variant
        lines.map do |line|
          tax = Qonto::PurchaseDefaults.tax_for(line[:vat_rate])
          quantity = Qonto::PurchaseDefaults.to_decimal(line[:quantity]) || 1
          unit = Qonto::PurchaseDefaults.to_decimal(line[:unit_pretax_amount])
          pretax = Qonto::PurchaseDefaults.to_decimal(line[:total_pretax_amount]) || (unit && unit * quantity)
          rate = Qonto::PurchaseDefaults.to_decimal(line[:vat_rate]) || 0
          { variant_id: variant&.id, conditioning_unit_id: variant&.default_unit&.id, conditioning_quantity: quantity,
            tax_id: tax&.id, unit_pretax_amount: unit, amount: pretax && (pretax * (1 + rate / 100)).round(2) }
        end
      end

      def header_item(inbound, debit)
        variant = Qonto::PurchaseDefaults.default_variant
        rate = single_vat_rate(inbound)
        tax = rate && Qonto::PurchaseDefaults.tax_for(rate)
        pretax = tax ? (debit / (1 + rate / 100)).round(2) : debit
        { variant_id: variant&.id, conditioning_unit_id: variant&.default_unit&.id, conditioning_quantity: 1,
          tax_id: tax&.id, unit_pretax_amount: pretax, amount: debit }
      end

      # Qonto's own tax split (taxes[]) when it has one rate; else the rate
      # that follows from the document's amounts.
      def single_vat_rate(inbound)
        rates = Array(inbound.payload.to_h.deep_stringify_keys['taxes']).map { |t| Qonto::PurchaseDefaults.to_decimal(t['tax_rate']) }.compact.uniq
        return rates.first if rates.one?

        return nil unless inbound.amount && inbound.pretax_amount&.positive?

        derived = ((inbound.amount / inbound.pretax_amount - 1) * 100).round(1)
        derived.positive? ? derived : nil
      end

      # A purchase entered by hand that nobody paid yet: same total, close in
      # time. Only a hint — the form does not link it, the accountant decides.
      def existing_purchase(item)
        amount = item.debit.to_d
        return nil unless amount.positive?

        window = (item.transfered_on - WINDOW_DAYS)..(item.transfered_on + WINDOW_DAYS)
        candidates = PurchaseInvoice.where('ABS(amount - ?) <= ?', amount, TOLERANCE).where(invoiced_at: window.begin.beginning_of_day..window.end.end_of_day)
        purchase = candidates.find { |p| !settled?(p) }
        return nil unless purchase

        ExpenseSuggestion.new(
          item: item, source: :existing_purchase, confidence: :medium, existing: purchase, supplier: purchase.supplier,
          warnings: [:already_entered], provenance: { existing: :history }
        )
      end

      # No document, but the supplier is known from past payments of this label.
      def supplier_model(item)
        supplier, how = resolved_supplier(item)
        return nil unless supplier

        model = model_for(supplier, item)
        nature = model ? model.nature_id : Qonto::PurchaseDefaults.default_nature&.id
        evidence = @last_evidence.to_i
        ExpenseSuggestion.new(
          item: item, source: :supplier_model, confidence: model && evidence >= 2 ? :medium : :low,
          supplier: supplier, supplier_how: how, nature_id: nature, invoiced_at: payment_date(item),
          description: item.name, items: model ? model.items : [], model_purchase: model&.purchase,
          warnings: model ? [] : [:no_model],
          provenance: { supplier: :history, items: (model ? :history : nil), nature: (model ? :history : :default) }.compact
        )
      end

      def resolved_supplier(item)
        @resolver ||= SupplierResolver.new
        result = @resolver.resolve(item)
        @last_evidence = result&.evidence
        result ? [result.entity, result.how] : [nil, nil]
      end

      def model_for(supplier, item)
        data = (item.provider || {}).to_h
        data = (data[:data] || data['data']).to_h.stringify_keys
        Qonto::LastPurchaseTemplate.for(supplier, item.debit.to_d, vat_details: data['vat_details'])
      end

      # The day the payment was made, when an exercise is open on it.
      def payment_date(item)
        [item.initiated_on, item.transfered_on].compact.find { |date| FinancialYear.on(date)&.opened? } || item.transfered_on
      end

      # Paid, at least in part: the bank line is not what it is waiting for.
      def settled?(purchase)
        affair = purchase.affair
        affair.present? && affair.purchase_payments.any?
      end
  end
end
