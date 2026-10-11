# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_lettering'

# The suggestions that come from what was done before: the supplier of a label
# already paid, and the shape of its latest purchase.
class Qonto::ExpenseSuggesterModelTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoLettering

  setup do
    @mode = outgoing_payment_modes(:outgoing_payment_modes_001)
    @cash = @mode.cash
    @supplier = entities(:entities_008)
  end

  def test_a_label_paid_before_gives_the_supplier_and_the_shape_of_its_last_purchase
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME SAS')
    purchase = @last_purchase
    item = unmatched_item(cash: @cash, label: 'ACME SAS', debit: 50)

    suggestion = suggest(item)

    assert_equal :supplier_model, suggestion.source
    assert_equal @supplier, suggestion.supplier
    assert_equal :learned_label, suggestion.supplier_how
    assert_equal purchase, suggestion.model_purchase
    assert_equal purchase.nature_id, suggestion.nature_id
    assert_equal 1, suggestion.items.size
    assert_equal BigDecimal('50'), suggestion.items_total
    assert suggestion.balanced?
    assert suggestion.creatable?
    assert_not suggestion.ready?, 'a guess is always validated by the accountant'
    assert_equal :low, suggestion.confidence, 'one earlier payment is thin'
    assert_equal 'ACME SAS', suggestion.description
  end

  def test_several_earlier_payments_make_it_more_trusted
    2.times { lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME SAS') }

    assert_equal :medium, suggest(unmatched_item(cash: @cash, label: 'ACME SAS', debit: 50)).confidence
  end

  def test_the_form_gets_the_supplier_the_nature_and_the_article
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME SAS')
    item = unmatched_item(cash: @cash, label: 'ACME SAS', debit: 50)

    params = suggest(item).form_params

    assert_equal({ third_id: @supplier.id }, params[:affair])
    assert_equal ProductNatureVariant.first.id.to_s, params[:trade][:items_attributes]['0'][:variant_id]
    assert_equal '50.0', params[:trade][:items_attributes]['0'][:amount]
  end

  def test_a_known_supplier_without_earlier_purchase_still_opens_the_form_but_says_so
    fresh = Entity.where.not(id: PurchaseInvoice.select(:supplier_id)).first
    item = unmatched_item(cash: @cash, label: 'CB 1', debit: 20, data: { counterparty_name: fresh.full_name })

    suggestion = suggest(item)

    assert_equal :supplier_model, suggestion.source
    assert_equal fresh, suggestion.supplier
    assert_empty suggestion.items
    assert_includes suggestion.warnings, :no_model
    assert suggestion.creatable?
  end

  def test_an_unknown_label_has_no_suggestion
    assert suggest(unmatched_item(cash: @cash, label: 'NEVER SEEN 7', debit: 20)).none?
  end

  def test_a_qonto_document_without_supplier_gets_one_from_the_label
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'INTERMARCHE')
    item = unmatched_item(cash: @cash, label: 'INTERMARCHE', debit: 35.13, provider_id: 'tx-im')
    Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'expense', entity: nil, amount: 35.13, currency: 'EUR',
                                  payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = suggest(item)

    assert_equal :inbound_invoice, suggestion.source
    assert_equal @supplier, suggestion.supplier
    assert_equal :learned_label, suggestion.supplier_how
    assert_not_includes suggestion.warnings, :no_supplier
    assert_equal :history, suggestion.provenance[:supplier]
  end

  def test_a_qonto_document_without_lines_takes_the_articles_of_the_last_purchase
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'INTERMARCHE')
    item = unmatched_item(cash: @cash, label: 'INTERMARCHE', debit: 35.13, provider_id: 'tx-im')
    Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'invoice', entity: @supplier, amount: 35.13, currency: 'EUR',
                                  payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = suggest(item)

    assert_equal ProductNatureVariant.first.id, suggestion.items.first[:variant_id]
    assert_equal BigDecimal('35.13'), suggestion.items_total
    assert_equal :history, suggestion.provenance[:items]
  end

  def test_a_document_with_its_own_lines_keeps_them
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'INTERMARCHE')
    item = unmatched_item(cash: @cash, label: 'INTERMARCHE', debit: 12.0, provider_id: 'tx-im')
    Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'invoice', entity: @supplier, amount: 12, currency: 'EUR',
                                  lines: [{ label: 'x', quantity: '1', unit_pretax_amount: '10', vat_rate: '20', total_pretax_amount: '10' }],
                                  payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = suggest(item)

    assert_equal :inbound, suggestion.provenance[:items]
    assert_nil suggestion.items.first[:variant_id] unless Qonto::PurchaseDefaults.default_variant
  end

  private

    def suggest(item)
      Qonto::ExpenseSuggester.for_all([item])[item.id]
    end
end
