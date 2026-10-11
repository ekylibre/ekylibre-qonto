# frozen_string_literal: true

module Qonto
  # The document is an invoice Ekylibre already has as a purchase. Links the two
  # instead of creating a second purchase: the file joins the existing one and
  # the inbox entry is closed as reconciled.
  class LinkToExistingPurchase
    class Error < StandardError; end

    def self.call(inbound, purchase)
      new(inbound, purchase).call
    end

    def initialize(inbound, purchase)
      @inbound = inbound
      @purchase = purchase
    end

    # @return [PurchaseInvoice]
    def call
      raise Error, 'only a purchase invoice can be linked' unless @purchase.is_a?(PurchaseInvoice)

      @inbound.with_lock do
        raise Error, 'this document is not a purchase' unless @inbound.purchasable?
        raise Error, 'this document is already linked to another purchase' if @inbound.purchase_id && @inbound.purchase_id != @purchase.id

        attach_document
        @inbound.update!(status: 'matched', purchase: @purchase, entity: @inbound.entity || @purchase.supplier)
      end
      @purchase
    end

    private

      def attach_document
        return unless @inbound.document && @purchase.respond_to?(:attachments)
        return if @purchase.attachments.where(document_id: @inbound.document_id).exists?

        @purchase.attachments.create!(document: @inbound.document)
      end
  end
end
