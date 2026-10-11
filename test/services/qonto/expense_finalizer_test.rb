# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::ExpenseFinalizerTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @mode = outgoing_payment_modes(:outgoing_payment_modes_001)
    @cash = @mode.cash
    @supplier = entities(:entities_008)
    @item = create_item('tx-1', debit: 120.0)
    @document = Document.create!(key: 'k-pdf', name: 'fa.pdf', processable_attachment: false)
    @inbound = Qonto::InboundInvoice.create!(
      remote_id: 'r-1', kind: 'invoice', entity: @supplier, document: @document, invoice_number: 'FA-1',
      payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-1' }] }
    )
  end

  def test_a_line_that_is_not_lettered_changes_nothing
    result = Qonto::ExpenseFinalizer.call(@item)

    assert_equal :not_lettered, result.status
    assert @inbound.reload.to_review?
  end

  def test_the_purchase_is_found_through_the_lettering_then_the_document_is_attached_and_the_inbound_closed
    purchase = create_lettered_purchase

    result = Qonto::ExpenseFinalizer.call(@item.reload)

    assert_equal :done, result.status
    assert_equal purchase, result.purchase
    assert_equal [@document.id], purchase.attachments.map(&:document_id)
    assert @inbound.reload.matched?
    assert_equal purchase, @inbound.purchase
  end

  def test_it_can_be_replayed
    create_lettered_purchase
    Qonto::ExpenseFinalizer.call(@item.reload)

    assert_no_difference 'Attachment.count' do
      assert_equal :done, Qonto::ExpenseFinalizer.call(@item.reload).status
    end
  end

  def test_a_lettered_line_without_purchase_behind_is_reported
    @item.update_columns(letter: 'ZZ')

    assert_equal :purchase_not_found, Qonto::ExpenseFinalizer.call(@item.reload).status
    assert @inbound.reload.to_review?
  end

  def test_without_a_matched_document_the_purchase_is_still_found
    purchase = create_lettered_purchase
    @inbound.destroy!

    result = Qonto::ExpenseFinalizer.call(@item.reload)

    assert_equal :done, result.status
    assert_equal purchase, result.purchase
  end

  private

    # What the reconciliation form does: purchase, payment, affair, lettering.
    def create_lettered_purchase
      purchase = PurchaseInvoice.create!(nature: PurchaseNature.first, supplier: @supplier, reference_number: 'FA-1',
                                         invoiced_at: Time.zone.local(2019, 10, 3), currency: 'EUR')
      purchase.items.create!(variant: ProductNatureVariant.first, tax: Tax.first, conditioning_quantity: 1,
                             conditioning_unit: ProductNatureVariant.first.default_unit, unit_pretax_amount: 120.0 / (1 + Tax.first.amount / 100))
      purchase.reload
      payment = PurchasePayment.create!(amount: purchase.amount, payee: @supplier, mode: @mode, currency: 'EUR',
                                        responsible: User.first, to_bank_at: Time.zone.local(2019, 10, 15), paid_at: Time.zone.local(2019, 10, 15))
      affair = purchase.affair
      affair.third = @supplier
      affair.save!
      affair.attach(payment)
      @item.update_columns(debit: purchase.amount)
      assert payment.letter_with(BankStatementItem.where(id: @item.id)), 'the payment could not be lettered with the bank line'
      purchase
    end

    def create_item(provider_id, debit:)
      statement = @cash.bank_statements.create!(
        number: "#{@cash.id}-2019-10", started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31)
      )
      statement.items.create!(
        name: "item #{provider_id}", transfered_on: Date.new(2019, 10, 15), debit: debit,
        provider: { vendor: 'qonto', name: 'transaction', id: provider_id, data: {} }
      )
    end
end
