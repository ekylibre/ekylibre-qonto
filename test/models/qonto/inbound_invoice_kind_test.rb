# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::InboundInvoiceKindTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_defaults_to_invoice
    assert_equal 'invoice', Qonto::InboundInvoice.create!(remote_id: 'd-1').kind
  end

  def test_rejects_an_unknown_kind
    refute Qonto::InboundInvoice.new(remote_id: 'd-2', kind: 'selfie').valid?
  end

  def test_kind_predicates_and_groups
    { 'invoice' => [true, false], 'expense' => [true, false], 'receipt' => [false, true], 'other' => [false, true] }.each do |kind, (purchasable, statement)|
      record = Qonto::InboundInvoice.new(kind: kind)
      assert record.public_send("#{kind}?"), kind
      assert_equal purchasable, record.purchasable?, "#{kind} purchasable"
      assert_equal statement, record.statement_document?, "#{kind} statement document"
    end
  end

  def test_of_kind_scope
    Qonto::InboundInvoice.create!(remote_id: 'k-a', kind: 'expense')
    Qonto::InboundInvoice.create!(remote_id: 'k-b', kind: 'receipt')

    assert_equal ['k-a'], Qonto::InboundInvoice.of_kind('expense').pluck(:remote_id)
  end

  def test_matched_transaction_ids_reads_both_string_and_symbol_keys_and_skips_transfers
    saved = Qonto::InboundInvoice.create!(
      remote_id: 'm-a',
      payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 't1' }, { subject_type: 'transfer', transaction_id: 'x1' }] }
    )

    assert_equal ['t1'], saved.matched_transaction_ids
    assert_equal ['t1'], Qonto::InboundInvoice.find(saved.id).matched_transaction_ids, 'after a database round trip'
    assert_equal [], Qonto::InboundInvoice.new.matched_transaction_ids
  end

  def test_line_items_come_back_with_symbol_keys
    record = Qonto::InboundInvoice.create!(remote_id: 'l-1', lines: [{ 'label' => 'A', 'quantity' => '2.0' }])

    assert_equal [{ label: 'A', quantity: '2.0' }], Qonto::InboundInvoice.find(record.id).line_items
  end

  def test_recent_orders_by_invoice_date_or_arrival_when_the_date_is_missing
    old = Qonto::InboundInvoice.create!(remote_id: 'o-1', issued_on: Date.new(2026, 1, 1))
    dated = Qonto::InboundInvoice.create!(remote_id: 'o-2', issued_on: Date.new(2026, 6, 1))
    undated = Qonto::InboundInvoice.create!(remote_id: 'o-3', issued_on: nil)

    ordered = Qonto::InboundInvoice.where(id: [old, dated, undated]).recent.to_a
    assert_equal undated, ordered.first, 'no date: counts as received today, not as the oldest'
    assert_equal old, ordered.last
  end

  def test_in_financial_year_uses_the_invoice_date_or_the_arrival_date_when_there_is_none
    year = FinancialYear.on(Date.new(2019, 10, 15))
    inside = Qonto::InboundInvoice.create!(remote_id: 'fy-1', issued_on: year.started_on)
    last_day = Qonto::InboundInvoice.create!(remote_id: 'fy-2', issued_on: year.stopped_on)
    before = Qonto::InboundInvoice.create!(remote_id: 'fy-3', issued_on: year.started_on - 1)
    after = Qonto::InboundInvoice.create!(remote_id: 'fy-4', issued_on: year.stopped_on + 1)
    undated_inside = Qonto::InboundInvoice.create!(remote_id: 'fy-5', issued_on: nil, created_at: year.started_on + 10)
    undated_outside = Qonto::InboundInvoice.create!(remote_id: 'fy-6', issued_on: nil)

    found = Qonto::InboundInvoice.in_financial_year(year)
    assert_equal [inside, last_day, undated_inside].map(&:id).sort, found.pluck(:id).sort, 'both bounds included'
    [before, after, undated_outside].each { |doc| refute_includes found, doc, doc.remote_id }
  end

  def test_in_financial_year_without_exercise_keeps_everything
    doc = Qonto::InboundInvoice.create!(remote_id: 'fy-7', issued_on: Date.new(1999, 1, 1))

    assert_includes Qonto::InboundInvoice.in_financial_year(nil), doc
  end
end
