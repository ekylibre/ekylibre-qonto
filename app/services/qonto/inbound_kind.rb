# frozen_string_literal: true

module Qonto
  # What a received document is. Ekylibre does not treat them as the same
  # object, so the inbox has to tell them apart:
  #
  #   invoice  — supplier invoice            → PurchaseInvoice
  #   expense  — expense report (note de frais) → PurchaseInvoice, "expense report" nature
  #   receipt  — card receipt                → supporting document of a bank line
  #   other    — any other financial document → supporting document of a bank line
  #
  # Qonto does not expose a "kind" field; the document category its
  # classifier assigns to the attachment is the closest signal
  # (GET /v2/supplier_invoices → attachment_category).
  module InboundKind
    KINDS = %w[invoice expense receipt other].freeze

    # Kinds that become a purchase vs. those only attached to a bank line.
    PURCHASE_KINDS = %w[invoice expense].freeze
    STATEMENT_KINDS = %w[receipt other].freeze

    CATEGORY_KINDS = {
      'INVOICE' => 'invoice',
      'EXPENSE_RECEIPT' => 'expense',
      'CARD_RECEIPT' => 'receipt'
    }.freeze

    # @param raw [Hash] a raw Qonto supplier-invoice payload
    # @return [String] one of KINDS
    def self.for(raw)
      # Delivered through the e-invoicing network: always a real invoice,
      # whatever label the classifier put on it.
      return 'invoice' if raw[:source_type].to_s == 'e_invoicing'

      CATEGORY_KINDS.fetch(raw[:attachment_category].to_s.upcase, 'other')
    end
  end
end
