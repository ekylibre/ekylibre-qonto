# frozen_string_literal: true

module Qonto
  # Closes the loop once the accountant created the purchase from a bank line
  # in the bank reconciliation form (which creates purchase, payment and
  # lettering): finds the purchase through the lettering, attaches the
  # supporting document and closes the received document. Safe to replay:
  # nothing happens when the line is not lettered, and what is done is not
  # done twice.
  class ExpenseFinalizer
    Result = Struct.new(:status, :purchase, keyword_init: true)

    def self.call(item)
      new(item).call
    end

    def initialize(item)
      @item = item
    end

    # @return [Result] status :not_lettered, :purchase_not_found or :done
    def call
      return Result.new(status: :not_lettered) if @item.letter.blank?

      purchase = purchase_for(@item)
      return Result.new(status: :purchase_not_found) unless purchase

      inbound = inbound_for(@item)
      attach_documents(purchase, inbound)
      close(inbound, purchase)
      Result.new(status: :done, purchase: purchase)
    end

    private

      # The reconciliation form letters the payment's entry with the bank line
      # (same statement, same bank letter); the payment belongs to the affair
      # of the purchase.
      def purchase_for(item)
        entries = JournalEntryItem.where(bank_statement_id: item.bank_statement_id, bank_statement_letter: item.letter).includes(:entry)
        payments = entries.map { |entry_item| entry_item.entry.resource }.grep(OutgoingPayment)
        purchases = payments.flat_map { |payment| payment.affair ? payment.affair.purchase_invoices.to_a : [] }.uniq
        purchases.one? ? purchases.first : nil
      end

      def inbound_for(item)
        id = Qonto::ExpenseSuggester.qonto_id(item)
        return nil if id.blank?

        InboundInvoice.where(status: 'to_review').find { |inbound| inbound.matched_transaction_ids.include?(id) }
      end

      # The supplier's document and what is attached to the bank line itself.
      def attach_documents(purchase, inbound)
        return unless purchase.respond_to?(:attachments)

        documents = [inbound&.document, *@item.attachments.map(&:document)].compact.uniq
        documents.each do |document|
          next if purchase.attachments.where(document_id: document.id).exists?

          purchase.attachments.create!(document: document)
        end
      end

      def close(inbound, purchase)
        return unless inbound

        inbound.with_lock do
          inbound.update!(status: 'matched', purchase: purchase) if inbound.to_review?
        end
      end
  end
end
