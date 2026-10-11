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

  def test_keeps_the_counterparty_and_vat_in_the_provider_data
    tx = build_transaction(id: 'q-3', transaction_id: 'tx-3', settled_at: '2019-10-14T09:00:00Z', amount: 27.7,
                           extra: enriched)
    Qonto::TransactionsImportService.call(cash: @cash, transactions: [tx])

    data = provider_data_of('q-3')
    assert_equal 'Google Play', data['counterparty_name']
    assert_equal 'FR7610278022840002017740114', data['counterparty_iban']
    assert_equal 'CMCIFR2AXXX', data['counterparty_bic']
    assert_equal 'OVH-MWLN9307456F', data['mandate_reference']
    assert_equal 2.8, data['vat_amount']
    assert_equal 'Déplacements', data['cashflow_category']
    assert_equal 'Autres frais de déplacement', data['cashflow_subcategory']
    assert_equal [{ 'rate' => 10.0, 'amount' => 2.17, 'amount_excluding_vat' => 21.7 }], data['vat_details']
    assert_not data.key?('note'), 'absent values are left out'
  end

  def test_reimport_fills_the_provider_data_of_an_item_imported_before_without_touching_it
    plain = build_transaction(id: 'q-4', transaction_id: 'tx-4', settled_at: '2019-10-15T09:00:00Z', amount: 5.0)
    Qonto::TransactionsImportService.call(cash: @cash, transactions: [plain])
    item = BankStatementItem.of_provider('qonto', 'transaction', 'q-4').first
    assert_nil provider_data_of('q-4')['counterparty_name']
    before = item.reload.attributes.except('provider', 'updated_at')

    enriched_tx = build_transaction(id: 'q-4', transaction_id: 'tx-4', settled_at: '2019-10-15T09:00:00Z', amount: 5.0,
                                    extra: enriched)
    assert_no_difference 'BankStatementItem.count' do
      Qonto::TransactionsImportService.call(cash: @cash, transactions: [enriched_tx])
    end

    assert_equal 'Google Play', provider_data_of('q-4')['counterparty_name']
    assert_equal before, item.reload.attributes.except('provider', 'updated_at')
  end

  private

    def enriched
      {
        clean_counterparty_name: 'Google Play',
        transfer: { counterparty_account_number: 'FR7610278022840002017740114', counterparty_bank_identifier: 'CMCIFR2AXXX',
                    unique_mandate_reference: 'OVH-MWLN9307456F' },
        vat_amount: 2.8,
        vat_rate: 10.0,
        vat_details: { items: [{ rate: 10.0, amount: 2.17, amount_excluding_vat: 21.7 }] },
        cashflow_category: { id: 'c1', name: 'Déplacements' },
        cashflow_subcategory: { id: 'c2', name: 'Autres frais de déplacement' },
        note: nil,
        card_last_digits: '5502'
      }
    end

    def provider_data_of(id)
      item = BankStatementItem.of_provider('qonto', 'transaction', id).first
      (item.provider[:data] || item.provider['data']).to_h.stringify_keys.transform_values { |v| v }
    end

    def build_transaction(id:, transaction_id:, settled_at:, amount:, extra: {})
      OpenStruct.new({
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
      }.merge(extra))
    end
end
