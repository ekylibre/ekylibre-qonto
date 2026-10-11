# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::AttachToBankStatementTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @cash = cashes(:cashes_001)
    @item = create_qonto_item('tx-uuid-1')
    @other_item = create_qonto_item('tx-uuid-other', cash: cashes(:cashes_002))
    @document = Document.create!(key: 'k-receipt', name: 'receipt.pdf', processable_attachment: false)
  end

  def test_attaches_the_document_to_the_matched_bank_line
    receipt = inbound(kind: 'receipt', transactions: [{ subject_type: 'transaction', transaction_id: 'tx-uuid-1' }])

    assert_difference 'Attachment.count', 1 do
      Qonto::AttachToBankStatement.call(receipt)
    end

    assert_equal [@document.id], @item.attachments.map(&:document_id)
    assert_empty @other_item.attachments, 'other lines are left alone'
    assert receipt.reload.matched?
    assert_nil receipt.purchase_id, 'no purchase is created for a receipt'
  end

  def test_works_for_other_documents_too
    other = inbound(kind: 'other', transactions: [{ subject_type: 'transaction', transaction_id: 'tx-uuid-1' }])

    Qonto::AttachToBankStatement.call(other)
    assert other.reload.matched?
  end

  def test_is_idempotent
    receipt = inbound(kind: 'receipt', transactions: [{ subject_type: 'transaction', transaction_id: 'tx-uuid-1' }])
    Qonto::AttachToBankStatement.call(receipt)

    assert_no_difference 'Attachment.count' do
      Qonto::AttachToBankStatement.call(receipt.reload)
    end
  end

  def test_ignores_transfers_matched_to_the_same_document
    receipt = inbound(kind: 'receipt', transactions: [{ subject_type: 'transfer', transaction_id: 'tx-uuid-1' }])

    error = assert_raises(Qonto::AttachToBankStatement::Error) { Qonto::AttachToBankStatement.call(receipt) }
    assert_match(/no matching bank line/, error.message)
  end

  def test_refuses_when_the_bank_line_is_not_synchronised_yet_and_changes_nothing
    receipt = inbound(kind: 'receipt', transactions: [{ subject_type: 'transaction', transaction_id: 'not-synchronised' }])

    assert_raises(Qonto::AttachToBankStatement::Error) { Qonto::AttachToBankStatement.call(receipt) }
    assert receipt.reload.to_review?, 'it stays in the inbox to be retried after the next bank sync'
  end

  def test_refuses_a_document_without_a_file
    receipt = inbound(kind: 'receipt', document: nil, transactions: [{ subject_type: 'transaction', transaction_id: 'tx-uuid-1' }])

    error = assert_raises(Qonto::AttachToBankStatement::Error) { Qonto::AttachToBankStatement.call(receipt) }
    assert_match(/not been downloaded/, error.message)
  end

  def test_refuses_invoices_and_expense_reports
    %w[invoice expense].each do |kind|
      doc = inbound(kind: kind, transactions: [{ subject_type: 'transaction', transaction_id: 'tx-uuid-1' }], remote_id: "k-#{kind}")
      assert_raises(Qonto::AttachToBankStatement::Error) { Qonto::AttachToBankStatement.call(doc) }
    end
  end

  def test_refuses_when_qonto_matched_no_transaction
    receipt = inbound(kind: 'receipt', transactions: [])

    assert_raises(Qonto::AttachToBankStatement::Error) { Qonto::AttachToBankStatement.call(receipt) }
  end

  private

    def inbound(kind:, transactions:, document: @document, remote_id: 'r-1')
      Qonto::InboundInvoice.create!(
        remote_id: remote_id, kind: kind, document: document,
        payload: { matched_transactions: transactions }
      )
    end

    def create_qonto_item(provider_id, cash: @cash)
      statement = cash.bank_statements.create!(
        number: "#{cash.id}-2019-10", started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31)
      )
      statement.items.create!(
        name: "item #{provider_id}", transfered_on: Date.new(2019, 10, 15), credit: 10.0,
        provider: { vendor: 'qonto', name: 'transaction', id: provider_id, data: {} }
      )
    end
end
