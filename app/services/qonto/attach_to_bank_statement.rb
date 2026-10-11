# frozen_string_literal: true

module Qonto
  # Card receipts and other financial documents are not purchases in Ekylibre:
  # they justify a bank line. This attaches the document to the bank statement
  # item(s) of the transaction(s) Qonto matched it with, and closes the inbox
  # entry. Nothing is created beyond the attachment.
  class AttachToBankStatement
    class Error < StandardError; end

    def self.call(inbound)
      new(inbound).call
    end

    def initialize(inbound)
      @inbound = inbound
    end

    # @return [Array<BankStatementItem>] the lines the document is attached to
    # @raise [Error] when it cannot be attached yet (nothing is changed then)
    def call
      # Under a row lock, so two clicks cannot attach the file twice.
      @inbound.with_lock do
        raise Error, 'this document is an invoice or an expense report' unless @inbound.statement_document?
        raise Error, 'the file has not been downloaded yet' unless @inbound.document

        items = bank_statement_items.to_a
        raise Error, 'no matching bank line: synchronise the bank account first' if items.empty?

        items.each do |item|
          next if item.attachments.where(document_id: @inbound.document_id).exists?

          item.attachments.create!(document: @inbound.document)
        end
        @inbound.update!(status: 'matched')
        items
      end
    end

    private

      def bank_statement_items
        ids = @inbound.matched_transaction_ids
        return BankStatementItem.none if ids.empty?

        BankStatementItem
          .of_provider_name(Qonto::TransactionsImportService::PROVIDER_VENDOR, Qonto::TransactionsImportService::PROVIDER_NAME)
          .where("(provider ->> 'id') IN (?)", ids)
      end
  end
end
