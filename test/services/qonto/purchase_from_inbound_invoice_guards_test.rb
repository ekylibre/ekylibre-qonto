# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# What stops "Create the purchase" from counting an invoice twice.
class Qonto::PurchaseFromInboundInvoiceGuardsTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008)
    @nature = PurchaseNature.by_default || PurchaseNature.first
    @inbound = create_inbound('FA-100')
  end

  # -- already entered -------------------------------------------------------

  def test_refuses_an_invoice_that_is_already_a_purchase_and_says_which
    existing = create_purchase('FA-100')

    error = nil
    assert_no_difference 'PurchaseInvoice.count' do
      error = assert_raises(Qonto::PurchaseFromInboundInvoice::DuplicateError) { Qonto::PurchaseFromInboundInvoice.call(@inbound) }
    end

    assert_equal existing, error.match.purchase
    assert_equal :same_supplier, error.match.certainty
    assert_includes error.message, existing.number
    assert @inbound.reload.to_review?, 'the inbox entry stays open'
  end

  def test_the_duplicate_error_is_an_error_like_the_others
    create_purchase('FA-100')

    assert_raises(Qonto::PurchaseFromInboundInvoice::Error) { Qonto::PurchaseFromInboundInvoice.call(@inbound) }
  end

  def test_the_accountant_can_insist_when_it_is_really_another_invoice
    create_purchase('FA-100')

    purchase = nil
    assert_difference 'PurchaseInvoice.count', 1 do
      purchase = Qonto::PurchaseFromInboundInvoice.call(@inbound, force: true)
    end
    assert_equal @inbound.reload.purchase_id, purchase.id
  end

  def test_a_number_only_shared_with_another_supplier_is_not_a_duplicate
    create_purchase('FA-100', supplier: entities(:entities_009), amount: 777)

    assert_difference 'PurchaseInvoice.count', 1 do
      Qonto::PurchaseFromInboundInvoice.call(@inbound)
    end
  end

  def test_an_expense_report_is_checked_too
    create_purchase('FA-100')
    expense = create_inbound('FA-100', kind: 'expense', remote_id: 'e-1')

    assert_raises(Qonto::PurchaseFromInboundInvoice::DuplicateError) { Qonto::PurchaseFromInboundInvoice.call(expense) }
  end

  # -- issued by your own company --------------------------------------------

  def test_refuses_an_invoice_your_own_company_issued
    company = Entity.of_company
    company.update_columns(siret_number: '12345678200019')
    own = create_inbound('F-OWN-1', remote_id: 'own-1', supplier_siret: '12345678200019')

    assert_no_difference 'PurchaseInvoice.count' do
      error = assert_raises(Qonto::PurchaseFromInboundInvoice::Error) { Qonto::PurchaseFromInboundInvoice.call(own) }
      assert_match(/own company/, error.message)
    end
    assert own.reload.to_review?
  end

  def test_not_even_forced_when_it_is_your_own_invoice
    company = Entity.of_company
    company.update_columns(siret_number: '12345678200019')
    own = create_inbound('F-OWN-2', remote_id: 'own-2', supplier_siret: '12345678200019')

    assert_raises(Qonto::PurchaseFromInboundInvoice::Error) { Qonto::PurchaseFromInboundInvoice.call(own, force: true) }
  end

  # -- two clicks at once ----------------------------------------------------

  def test_a_second_click_finds_the_purchase_the_first_one_created
    # Two requests each loaded the document before either created the purchase:
    # the second holds a stale copy that still says "no purchase yet".
    first = Qonto::InboundInvoice.find(@inbound.id)
    second = Qonto::InboundInvoice.find(@inbound.id)

    created = Qonto::PurchaseFromInboundInvoice.call(first)
    assert_nil second.purchase_id, 'the stale copy knows nothing yet'

    assert_no_difference 'PurchaseInvoice.count' do
      assert_equal created, Qonto::PurchaseFromInboundInvoice.call(second)
    end
  end

  def test_the_statement_attachment_is_not_repeated_by_a_second_click
    cash = cashes(:cashes_001)
    statement = cash.bank_statements.create!(number: 'g-1', started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31))
    item = statement.items.create!(name: 'i', transfered_on: Date.new(2019, 10, 15), credit: 10.0,
                                   provider: { vendor: 'qonto', name: 'transaction', id: 'tx-g', data: {} })
    document = Document.create!(key: 'k-g', name: 'r.pdf', processable_attachment: false)
    receipt = Qonto::InboundInvoice.create!(remote_id: 'rc-g', kind: 'receipt', document: document,
                                            payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-g' }] })
    stale = Qonto::InboundInvoice.find(receipt.id)

    Qonto::AttachToBankStatement.call(receipt)
    Qonto::AttachToBankStatement.call(stale)

    assert_equal 1, item.attachments.where(document_id: document.id).count
  end

  private

    def create_inbound(number, remote_id: 'g-1', kind: 'invoice', supplier_siret: nil)
      Qonto::InboundInvoice.create!(remote_id: remote_id, kind: kind, entity: @supplier, invoice_number: number, currency: 'EUR',
                                    issued_on: Date.new(2019, 10, 15), amount: 120, pretax_amount: 100, supplier_siret: supplier_siret)
    end

    def create_purchase(reference, supplier: @supplier, amount: nil)
      purchase = PurchaseInvoice.create!(nature: @nature, supplier: supplier, reference_number: reference,
                                         invoiced_at: Date.new(2019, 10, 15).to_time, currency: 'EUR')
      purchase.update_columns(amount: amount) if amount
      purchase
    end
end
