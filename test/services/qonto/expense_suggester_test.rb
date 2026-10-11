# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::ExpenseSuggesterTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @cash = cashes(:cashes_001)
    # No earlier purchase: the lines come from the document alone, not from a model.
    @supplier = Entity.where.not(id: PurchaseInvoice.select(:supplier_id)).where.not(id: Entity.of_company.id).first
    @tax = Tax.where(amount: 20).first || create_tax(20)
    @item = create_item('tx-1', debit: 120.0)
  end

  def test_a_document_matched_by_qonto_gives_a_ready_suggestion
    inbound = create_inbound(entity: @supplier, invoice_number: 'FA-9', issued_on: Date.new(2019, 10, 3),
                             lines: [{ label: 'Semences', quantity: '10', unit_pretax_amount: '10', vat_rate: '20', total_pretax_amount: '100' }])

    suggestion = suggest(@item)

    assert_equal :inbound_invoice, suggestion.source
    assert_equal inbound, suggestion.inbound
    assert_equal @supplier, suggestion.supplier
    assert_equal 'FA-9', suggestion.reference_number
    assert_equal Date.new(2019, 10, 3), suggestion.invoiced_at.to_date
    assert_equal :high, suggestion.confidence
    assert_equal [{ variant_id: nil, conditioning_unit_id: nil, conditioning_quantity: 10, tax_id: @tax.id, unit_pretax_amount: 10, amount: 120 }],
                 suggestion.items.map { |i| i.transform_values { |v| v.is_a?(BigDecimal) ? v.to_i : v } }
    assert suggestion.balanced?
    assert suggestion.ready?
    assert_empty suggestion.warnings
  end

  def test_without_lines_one_line_is_made_at_the_documents_vat_rate
    create_inbound(entity: @supplier, payload_extra: { taxes: [{ tax_rate: '20', tax_amount: { value: '20.0' } }] })

    suggestion = suggest(@item)

    assert_equal 1, suggestion.items.size
    item = suggestion.items.first
    assert_equal @tax.id, item[:tax_id]
    assert_equal BigDecimal('100.0'), item[:unit_pretax_amount]
    assert_equal BigDecimal('120.0'), item[:amount]
    assert_equal :medium, suggestion.confidence
    assert suggestion.balanced?
  end

  def test_without_a_known_rate_the_line_is_the_total_and_the_tax_is_left_to_choose
    create_inbound(entity: @supplier)

    item = suggest(@item).items.first

    assert_nil item[:tax_id]
    assert_equal BigDecimal('120.0'), item[:amount]
  end

  def test_the_total_that_differs_from_the_bank_line_is_flagged
    create_inbound(entity: @supplier, lines: [{ label: 'x', quantity: '1', unit_pretax_amount: '50', vat_rate: '20', total_pretax_amount: '50' }])

    suggestion = suggest(@item)

    assert_includes suggestion.warnings, :amount_mismatch
    assert_not suggestion.balanced?
    assert_not suggestion.ready?
    assert suggestion.creatable?, 'the accountant can still fix the lines in the form'
  end

  def test_a_missing_supplier_is_flagged_and_not_ready
    create_inbound(entity: nil)

    suggestion = suggest(@item)

    assert_includes suggestion.warnings, :no_supplier
    assert_not suggestion.ready?
  end

  def test_a_credit_note_cannot_be_created_as_a_purchase
    create_inbound(entity: @supplier, payload_extra: { is_credit_note: true })

    suggestion = suggest(@item)

    assert_includes suggestion.warnings, :credit_note
    assert_not suggestion.creatable?
  end

  def test_an_invoice_issued_by_the_own_company_is_not_a_purchase
    company = Entity.of_company
    create_inbound(entity: company)

    suggestion = suggest(@item)

    assert_includes suggestion.warnings, :own_company
    assert_not suggestion.creatable?
  end

  def test_a_purchase_already_entered_for_the_document_is_shown_instead
    inbound = create_inbound(entity: @supplier, invoice_number: 'FA-DUP')
    purchase = PurchaseInvoice.create!(nature: PurchaseNature.first, supplier: @supplier, reference_number: 'FA-DUP',
                                       invoiced_at: Time.zone.local(2019, 10, 2), currency: 'EUR')

    suggestion = suggest(@item)

    assert_equal :existing_purchase, suggestion.source
    assert_equal purchase, suggestion.existing
    assert_includes suggestion.warnings, :already_entered
    assert_equal inbound, suggestion.inbound
    assert_not suggestion.creatable?
  end

  def test_an_unpaid_purchase_of_the_same_total_nearby_is_shown_without_any_document
    purchase = PurchaseInvoice.create!(nature: PurchaseNature.first, supplier: @supplier, reference_number: 'MAN-1',
                                       invoiced_at: Time.zone.local(2019, 10, 1), currency: 'EUR')
    purchase.update_columns(amount: 120.0)

    suggestion = suggest(@item)

    assert_equal :existing_purchase, suggestion.source
    assert_equal purchase, suggestion.existing
    assert_equal :medium, suggestion.confidence
  end

  def test_a_purchase_of_the_same_total_far_away_in_time_is_not_suggested
    purchase = PurchaseInvoice.create!(nature: PurchaseNature.first, supplier: @supplier, reference_number: 'OLD',
                                       invoiced_at: Time.zone.local(2019, 3, 1), currency: 'EUR')
    purchase.update_columns(amount: 120.0)

    assert suggest(@item).none?
  end

  def test_a_receipt_matched_by_qonto_is_not_a_purchase
    create_inbound(entity: @supplier, kind: 'receipt')

    assert suggest(@item).none?
  end

  def test_a_line_without_any_document_has_no_suggestion
    suggestion = suggest(@item)

    assert suggestion.none?
    assert_not suggestion.creatable?
  end

  def test_an_inbound_already_turned_into_a_purchase_is_not_suggested_again
    create_inbound(entity: @supplier, status: 'matched')

    assert suggest(@item).none?
  end

  def test_the_form_parameters_are_the_ones_the_core_form_accepts
    create_inbound(entity: @supplier, invoice_number: 'FA-9', issued_on: Date.new(2019, 10, 3),
                   lines: [{ label: 'x', quantity: '10', unit_pretax_amount: '10', vat_rate: '20', total_pretax_amount: '100' }])

    params = suggest(@item).form_params(redirect: '/qonto/expenses/1/finalize')

    assert_equal [@item.id], params[:bank_statement_item_ids]
    assert_equal({ third_id: @supplier.id }, params[:affair])
    assert_equal '/qonto/expenses/1/finalize', params[:redirect]
    assert_equal 'FA-9', params[:trade][:reference_number]
    assert_equal '2019-10-03', params[:trade][:invoiced_at]
    line = params[:trade][:items_attributes]['0']
    assert_equal '10.0', line[:unit_pretax_amount], 'plain digits, not 0.1e2'
    assert_equal '120.0', line[:amount]
    assert_equal @tax.id.to_s, line[:tax_id]
  end

  private

    def suggest(item)
      Qonto::ExpenseSuggester.for_all([item])[item.id]
    end

    def create_tax(rate)
      Tax.create!(name: "TVA #{rate}", amount: rate, nature: :normal_vat, country: 'fr',
                  collect_account: Account.first, deduction_account: Account.first)
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

    def create_inbound(entity:, kind: 'invoice', status: 'to_review', invoice_number: 'FA-1', issued_on: Date.new(2019, 10, 3),
                       lines: [], payload_extra: {}, amount: 120, pretax_amount: nil)
      Qonto::InboundInvoice.create!(
        remote_id: "r-#{SecureRandom.hex(4)}", kind: kind, status: status, entity: entity, invoice_number: invoice_number,
        issued_on: issued_on, amount: amount, pretax_amount: pretax_amount, currency: 'EUR', lines: lines,
        payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-1' }] }.merge(payload_extra)
      )
    end
end
