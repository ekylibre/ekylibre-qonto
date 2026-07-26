# frozen_string_literal: true

module Qonto
  # A supplier e-invoice received through the Plateforme Agréée (reception,
  # regulatory deadline 01/09/2026). Persisted so we can index by status,
  # keep an audit trail, and pre-reconcile the supplier before an accountant
  # turns it into a Purchase.
  class InboundInvoice < ApplicationRecord
    self.table_name = 'qonto_inbound_invoices'

    STATUSES = %w[to_review matched ignored].freeze

    belongs_to :entity, optional: true     # supplier, guessed by SIRET
    belongs_to :purchase, optional: true   # purchase created from it
    belongs_to :document, optional: true   # PDF / Factur-X

    validates :remote_id, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }

    scope :to_review, -> { where(status: 'to_review') }
    scope :matched,   -> { where(status: 'matched') }
    scope :ignored,   -> { where(status: 'ignored') }
    scope :recent,    -> { order(issued_on: :desc, created_at: :desc) }

    STATUSES.each do |s|
      define_method("#{s}?") { status == s }
    end

    # A supplier is considered known when it has been matched to an Entity.
    def supplier_known?
      entity_id.present?
    end
  end
end
