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

  def test_the_vat_split_printed_on_the_document_gives_one_line_per_rate
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'INTERMARCHE')
    item = unmatched_item(cash: @cash, label: 'INTERMARCHE', debit: 17.23, provider_id: 'tx-im')
    inbound = Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'expense', entity: @supplier, amount: 17.23, currency: 'EUR',
                                            payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = with_receipt(inbound, receipt(date: '2026-09-14', number: 'T-77', vat_lines: [
      { rate: BigDecimal('5.5'), pretax: BigDecimal('7.80'), vat: BigDecimal('0.43'), total: BigDecimal('8.23') },
      { rate: BigDecimal('20'), pretax: BigDecimal('7.50'), vat: BigDecimal('1.50'), total: BigDecimal('9.00') }
    ])) { suggest(item) }

    assert_equal 2, suggestion.items.size
    assert_equal BigDecimal('17.23'), suggestion.items_total
    assert_equal :receipt, suggestion.provenance[:items]
    assert_equal 'T-77', suggestion.reference_number
    assert_equal :receipt, suggestion.provenance[:reference_number]
    assert_equal ProductNatureVariant.first.id, suggestion.items.first[:variant_id], 'the supplier\'s usual article is kept'
    assert_not_includes suggestion.warnings, :receipt_amount_mismatch
  end

  def test_a_document_that_does_not_show_the_amount_paid_is_flagged
    item = unmatched_item(cash: @cash, label: 'INTERMARCHE', debit: 17.23, provider_id: 'tx-im')
    inbound = Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'invoice', entity: @supplier, amount: 17.23, currency: 'EUR',
                                            payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = with_receipt(inbound, receipt(total_candidates: [BigDecimal('99.90')])) { suggest(item) }

    assert_includes suggestion.warnings, :receipt_amount_mismatch
  end

  def test_the_siret_printed_on_the_document_names_the_supplier_when_nothing_else_does
    @supplier.update_columns(siret_number: '12345678200019')
    item = unmatched_item(cash: @cash, label: 'UNKNOWN 9', debit: 17.23, provider_id: 'tx-im')
    inbound = Qonto::InboundInvoice.create!(remote_id: 'r-im', kind: 'invoice', entity: nil, amount: 17.23, currency: 'EUR',
                                            payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-im' }] })

    suggestion = with_receipt(inbound, receipt(siret: '12345678200019')) { suggest(item) }

    assert_equal @supplier, suggestion.supplier
    assert_equal :receipt, suggestion.supplier_how
    assert_equal :receipt, suggestion.provenance[:supplier]
  end

  def test_a_file_attached_to_the_bank_line_names_the_supplier_by_its_siret
    @supplier.update_columns(siret_number: '12345678200019')
    item = unmatched_item(cash: @cash, label: 'NEVER SEEN 8', debit: 17.23)
    item.attachments.create!(document: Document.create!(key: 'att-x', name: 'x.pdf', processable_attachment: false))
    result = receipt(siret: '12345678200019', number: 'T-9', vat_lines: [
      { rate: BigDecimal('20'), pretax: BigDecimal('14.36'), vat: BigDecimal('2.87'), total: BigDecimal('17.23') }
    ])

    suggestion = with_receipt(nil, result) { suggest(item) }

    assert_equal :supplier_model, suggestion.source
    assert_equal @supplier, suggestion.supplier
    assert_equal :receipt, suggestion.supplier_how
    assert_equal 'T-9', suggestion.reference_number
    assert_equal BigDecimal('17.23'), suggestion.items_total
    assert_equal item.attachments.first.document, suggestion.document
  end

  private

    def receipt(**attrs)
      Qonto::ReceiptReader::Result.new(
        { method: 'text', total: nil, total_candidates: [BigDecimal('17.23')], date: nil, number: nil, siret: nil, vat_number: nil,
          vat_lines: [], vat_consistent: !attrs[:vat_lines].to_a.empty? }.merge(attrs)
      )
    end

    # The reader needs a stored document: stand in for it.
    def with_receipt(_inbound, result)
      original = Qonto::ReceiptReader.method(:read)
      Qonto::ReceiptReader.define_singleton_method(:read) { |_document| result }
      Qonto::InboundInvoice.any_instance.stubs(:document).returns(Document.new) if Qonto::InboundInvoice.respond_to?(:any_instance)
      yield
    ensure
      Qonto::ReceiptReader.define_singleton_method(:read, original)
    end

    def suggest(item)
      Qonto::ExpenseSuggester.for_all([item])[item.id]
    end
end
