# frozen_string_literal: true

module Qonto
  # Translates raw PA/API error codes into human, actionable messages — never
  # expose API jargon in a farming ERP UI (see the doc's error annex).
  class ErrorTranslator
    KNOWN = %w[
      recipient_not_reachable_on_einvoicing
      invoice_not_in_draft_status
      forbidden_invoice_update
    ].freeze

    def self.human(code)
      code = code.to_s
      key = KNOWN.include?(code) ? "einvoice_error_#{code}" : 'einvoice_error_generic'
      key.to_sym.tl
    end
  end
end
