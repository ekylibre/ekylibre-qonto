# frozen_string_literal: true

module Qonto
  class TransactionsImportService
    PROVIDER_VENDOR = 'qonto'
    PROVIDER_NAME = 'transaction'

    # transaction object
    #
    # side in [debit, credit]
    # operation_type in [income, transfer, card, direct_debit, qonto_fee, cheque, recall, swift_income]
    # category in [transport, online_service, subscription, food_and_grocery, restaurant_and_bar, other_income, hardware_and_equipment, other_service, utility, tax, salary, other_expense]
    # 
    # :transaction_id=>"ekylibre-8704-1-transaction-50",
    # :amount=>3.3,
    # :amount_cents=>330,
    # :settled_balance=>76873.08,
    # :settled_balance_cents=>7687308,
    # :attachment_ids=>[],
    # :local_amount=>3.3,
    # :local_amount_cents=>330,
    # :side=>"debit",
    # :operation_type=>"card",
    # :currency=>"EUR",
    # :local_currency=>"EUR",
    # :label=>"HORODATEURS BX",
    # :settled_at=>"2023-09-09T15:27:52.285Z",
    # :emitted_at=>"2023-09-08T09:58:31.082Z",
    # :updated_at=>"2023-09-09T16:31:15.278Z",
    # :status=>"completed",
    # :note=>nil,
    # :reference=>nil,
    # :vat_amount=>nil,
    # :vat_amount_cents=>nil,
    # :vat_rate=>nil,
    # :initiator_id=>"0a08e729-3bd2-4da0-8571-ea83fc93189f",
    # :label_ids=>[],
    # :attachment_lost=>false,
    # :attachment_required=>true,
    # :card_last_digits=>"5502",
    # :category=>"transport",
    # :id=>"6cbb638b-e428-49e0-b60b-8ba7567d144c",
    # :subject_type=>"Card"

    class MissingTransactionIdError < StandardError
      def initialize(msg = 'Missing uniq id for transaction')
        super
      end
    end

    def self.call(*args)
      new(*args).call
    end

    def initialize(cash:, transactions:)
      @cash = cash
      @transactions = transactions
    end

    def call
      transactions_by_month.each do |beginning_of_month, transaction_items|
        bank_statement = find_or_create_bank_statement(beginning_of_month)
        next if bank_statement.nil?

        transaction_items.each do |transaction_item|
          next if bank_statement_item_already_exists?(transaction_item)

          create_bank_statement_item(bank_statement, transaction_item)
        end

        recalculate_debit_credit(bank_statement)
      end
    end

    private
      attr_reader :cash, :transactions

      def transactions_by_month
        transactions.group_by do |item|
          date = item.settled_at.to_date
          date.beginning_of_month.to_date
        end
      end

      def find_or_create_bank_statement(beginning_of_month)
        end_of_month = beginning_of_month.end_of_month
        number = "#{beginning_of_month.year}-#{beginning_of_month.month}"

        bank_statement = BankStatement.find_by(cash: cash, number: number, started_on: beginning_of_month, stopped_on: end_of_month)
        return bank_statement if bank_statement.present?

        return unless bank_statement_can_be_created?(beginning_of_month)

        # The bank statement bookkeeps on stopped_on: skip the month when no
        # financial year covers it, otherwise the journal entry is invalid and
        # raises ActiveRecord::RecordInvalid. It can be re-imported once the
        # matching financial year exists.
        unless financial_year_on?(end_of_month)
          Rails.logger.warn "[Qonto] Bank statement #{number} for cash ##{cash.id} skipped: no financial year covers #{end_of_month}."
          return
        end

        BankStatement.create!(cash: cash, number: number, started_on: beginning_of_month, stopped_on: end_of_month)
      end

      def bank_statement_can_be_created?(beginning_of_month)
        end_of_month = beginning_of_month.end_of_month
        BankStatement.for_cash(cash).between(beginning_of_month, end_of_month).empty?
      end

      def bank_statement_item_already_exists?(item)
        (item.transaction_number.present? && BankStatementItem.find_by(transaction_number: item.transaction_id)) ||
          (item.id.present? && BankStatementItem.of_provider(PROVIDER_VENDOR, PROVIDER_NAME, item.id).any?)
      end

      def create_bank_statement_item(bank_statement, item)
        raise MissingTransactionIdError.new if item.id.blank?

        # The item bookkeeps on transfered_on (settled_at): skip the transaction
        # when no financial year covers that date, otherwise the journal entry is
        # invalid and raises ActiveRecord::RecordInvalid. It will be re-imported
        # once the matching financial year exists.
        transfered_on = item.settled_at.to_date
        unless financial_year_on?(transfered_on)
          Rails.logger.warn "[Qonto] Transaction #{item.id} skipped: no financial year covers #{transfered_on}."
          return
        end

        bank_statement.items.create!(attributes(item))
      end

      def financial_year_on?(date)
        FinancialYear.on(date).present?
      end

      def attributes(item)
        { 
          transaction_number: item.transaction_id,
          transaction_nature: item.operation_type,
          initiated_on: item.emitted_at.to_date,
          name: item.label,
          memo: item.reference,
          balance: compute_balance(item),
          transfered_on: item.settled_at.to_date,
          provider:
            {
              vendor: PROVIDER_VENDOR,
              name: PROVIDER_NAME,
              id: item.id,
              data:  {
                operation_type: item.operation_type,
                category: item.category,
                subject_type: item.subject_type,
                attachment_ids: item.attachment_ids
              }
            }
        }
      end

      def compute_balance(item)
        if item.side == 'debit'
          value = - item.amount.to_d
        elsif item.side == 'credit'
          value = item.amount.to_d
        end
        value
      end

      def recalculate_debit_credit(bank_statement)
        bank_statement.reload.save!
      end

  end
end
