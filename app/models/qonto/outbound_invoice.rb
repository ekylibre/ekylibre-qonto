# frozen_string_literal: true

module Qonto
  # Tracks the emission of a Sale as an electronic invoice through the PA
  # (emission, regulatory deadline 01/09/2027). Kept as its own record so we can
  # index by status ("what is stuck?"), count poll attempts and, above all, keep
  # an audit trail — fiscal compliance has to be proven.
  class OutboundInvoice < ApplicationRecord
    self.table_name = 'qonto_outbound_invoices'

    STATUSES = %w[pending submitted issued received failed].freeze
    IN_PROGRESS = %w[pending submitted issued].freeze

    # Lifecycle steps shown in the timeline: Qonto status_code → label → the
    # local status it drives (200 Déposée, 201 Émise, 202 Reçue).
    STEPS = [
      { code: '200', label: 'deposited', status: 'submitted' },
      { code: '201', label: 'issued',    status: 'issued' },
      { code: '202', label: 'received',  status: 'received' }
    ].freeze

    belongs_to :sale

    validates :sale, presence: true, uniqueness: true
    validates :status, inclusion: { in: STATUSES }

    scope :failed,      -> { where(status: 'failed') }
    scope :in_progress, -> { where(status: IN_PROGRESS) }
    scope :recent,      -> { order(created_at: :desc) }
    # Submitted a while ago but never issued: the silent PA drift (S4 guard).
    scope :stalled, ->(since = 48.hours.ago) { where(status: 'submitted').where('submitted_at < ?', since) }

    def in_progress?
      IN_PROGRESS.include?(status)
    end

    def failed?
      status == 'failed'
    end

    def received?
      status == 'received'
    end

    # The step object for a given code, or nil.
    def event_for(code)
      Array(lifecycle_events).find { |e| e['code'].to_s == code.to_s }
    end
  end
end
