# frozen_string_literal: true

# What the bank reconciliation form leaves behind: a purchase, its payment, and
# the payment lettered with a Qonto bank line. Used to give the suggestions a
# history to learn from.
module QontoLettering
  def lettering_statement(cash)
    @lettering_statement ||= cash.bank_statements.find_by(number: "#{cash.id}-2019-10") ||
                             cash.bank_statements.create!(number: "#{cash.id}-2019-10", started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31))
  end

  def usable_taxes
    @usable_taxes ||= Tax.where('amount > 0').reorder(:id).to_a
  end

  # @param lines [Array<Hash>] [{ tax:, unit_pretax_amount: }]
  # @return [BankStatementItem] the lettered line (its purchase: item.purchase_for_test)
  def lettered_purchase(cash:, mode:, supplier:, label:, invoiced_at: Time.zone.local(2019, 10, 3), lines: nil, iban: nil, provider_id: SecureRandom.hex(4))
    lines ||= [{ tax: usable_taxes.first, unit_pretax_amount: 100 }]
    purchase = PurchaseInvoice.create!(nature: PurchaseNature.first, supplier: supplier, reference_number: "H-#{provider_id}",
                                       invoiced_at: invoiced_at, currency: 'EUR')
    variant = ProductNatureVariant.first
    lines.each do |line|
      purchase.items.create!(variant: variant, tax: line[:tax], conditioning_quantity: 1, conditioning_unit: variant.default_unit,
                             unit_pretax_amount: line[:unit_pretax_amount])
    end
    purchase.reload
    @last_purchase = purchase
    payment = PurchasePayment.create!(amount: purchase.amount, payee: supplier, mode: mode, currency: 'EUR', responsible: User.first,
                                      to_bank_at: Time.zone.local(2019, 10, 15), paid_at: Time.zone.local(2019, 10, 15))
    affair = purchase.affair
    affair.third = supplier
    affair.save!
    affair.attach(payment)
    item = lettering_statement(cash).items.create!(
      name: label, transfered_on: Date.new(2019, 10, 15), debit: purchase.amount,
      provider: { vendor: 'qonto', name: 'transaction', id: provider_id, data: { counterparty_iban: iban }.compact }
    )
    raise 'could not letter the payment with the bank line' unless payment.letter_with(BankStatementItem.where(id: item.id))

    item.reload
  end

  def unmatched_item(cash:, label:, debit:, provider_id: SecureRandom.hex(4), data: {})
    lettering_statement(cash).items.create!(
      name: label, transfered_on: Date.new(2019, 10, 20), debit: debit,
      provider: { vendor: 'qonto', name: 'transaction', id: provider_id, data: data }
    )
  end
end
