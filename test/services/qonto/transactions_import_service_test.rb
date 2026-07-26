# frozen_string_literal: true

require 'test_helper'
require 'ostruct'

# AC4 — importing the same Qonto transactions twice must not create duplicate
# BankStatementItems (idempotence on the Qonto provider id / transaction_id).
class Qonto::TransactionsImportServiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @cash = cashes(:cashes_001)
    # Dates within an existing opened financial year (2019-09 → 2020-08) so the
    # service's financial-year guard does not skip the items.
    @transactions = [
      build_transaction(id: 'q-1', transaction_id: 'tx-1', settled_at: '2019-10-10T09:00:00Z', amount: 12.5),
      build_transaction(id: 'q-2', transaction_id: 'tx-2', settled_at: '2019-10-12T09:00:00Z', amount: 8.0)
    ]
  end

  def test_import_is_idempotent
    assert_difference 'BankStatementItem.count', 2 do
      Qonto::TransactionsImportService.call(cash: @cash, transactions: @transactions)
    end

    assert_no_difference 'BankStatementItem.count', 'a second import of the same payload must be a no-op' do
      Qonto::TransactionsImportService.call(cash: @cash, transactions: @transactions)
    end
  end

  private

    def build_transaction(id:, transaction_id:, settled_at:, amount:)
      OpenStruct.new(
        id: id,
        transaction_id: transaction_id,
        operation_type: 'card',
        emitted_at: settled_at,
        settled_at: settled_at,
        label: "Transaction #{transaction_id}",
        reference: nil,
        side: 'debit',
        amount: amount,
        category: 'other_expense',
        subject_type: 'Card',
        attachment_ids: []
      )
    end
end
