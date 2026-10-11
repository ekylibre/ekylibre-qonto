# frozen_string_literal: true

module Qonto
  # A supplier e-invoice received through the Plateforme Agréée (reception,
  # regulatory deadline 01/09/2026). Persisted so we can index by status,
  # keep an audit trail, and pre-reconcile the supplier before an accountant
  # turns it into a Purchase.
  class InboundInvoice < ApplicationRecord
    self.table_name = 'qonto_inbound_invoices'

    STATUSES = %w[to_review matched ignored].freeze
    KINDS = Qonto::InboundKind::KINDS

    belongs_to :entity, optional: true     # supplier, guessed by SIRET
    belongs_to :purchase, optional: true   # purchase created from it
    belongs_to :document, optional: true   # PDF / Factur-X

    validates :remote_id, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }
    validates :kind, inclusion: { in: KINDS }

    scope :to_review, -> { where(status: 'to_review') }
    scope :matched,   -> { where(status: 'matched') }
    scope :ignored,   -> { where(status: 'ignored') }
    # Filed under the exercise of the invoice date, or of the day the document
    # arrived when Qonto has no date for it (as the inbox displays it). No
    # exercise at all (new tenant): everything.
    scope :in_financial_year, lambda { |financial_year|
      next all unless financial_year

      where('COALESCE(qonto_inbound_invoices.issued_on, qonto_inbound_invoices.created_at::date) BETWEEN ? AND ?',
            financial_year.started_on, financial_year.stopped_on)
    }
    scope :of_kind,   ->(kind) { where(kind: kind) }
    scope :recent,    -> { order(Arel.sql('COALESCE(issued_on, created_at::date) DESC'), created_at: :desc) }

    STATUSES.each do |s|
      define_method("#{s}?") { status == s }
    end

    KINDS.each do |k|
      define_method("#{k}?") { kind == k }
    end

    # Becomes a PurchaseInvoice (supplier invoice, expense report).
    def purchasable?
      Qonto::InboundKind::PURCHASE_KINDS.include?(kind)
    end

    # Only a supporting document of a bank line (card receipt, other).
    def statement_document?
      Qonto::InboundKind::STATEMENT_KINDS.include?(kind)
    end

    # Qonto ids of the bank transactions the platform already matched to this
    # document (payload.matched_transactions[].transaction_id — the `id` of
    # the transaction, stored as provider id on the bank statement item).
    # Transfers matched to the same document are not bank lines.
    def matched_transaction_ids
      Array(payload.to_h.deep_stringify_keys['matched_transactions'])
        .select { |t| t['subject_type'].blank? || t['subject_type'] == 'transaction' }
        .map { |t| t['transaction_id'] }.compact
    end

    # The structured lines, as normalized hashes with symbol keys.
    def line_items
      Array(lines).map { |l| l.to_h.symbolize_keys }
    end

    # A supplier is considered known when it has been matched to an Entity.
    def supplier_known?
      entity_id.present?
    end
  end
end
