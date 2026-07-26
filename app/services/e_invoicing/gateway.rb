# frozen_string_literal: true

module EInvoicing
  # Port / interface for electronic invoicing, decoupled from any Plateforme
  # Agréée. The vocabulary is regulatory (submit / issued / received), never
  # Qonto's. A change of PA — or Qonto aligning on AFNOR XP Z12-013 — moves the
  # adapter only.
  #
  # Concrete implementations live under EInvoicing::Adapters.
  class Gateway
    # Uniform return value for the write path.
    Result = Struct.new(:ok, :value, :error_code, :error_detail, keyword_init: true) do
      def ok?
        !!ok
      end

      def self.success(value = nil)
        new(ok: true, value: value)
      end

      def self.failure(error_code, error_detail = nil)
        new(ok: false, error_code: error_code, error_detail: error_detail)
      end
    end

    class << self
      # Selects the adapter for the current tenant: the Qonto adapter as soon as
      # a Qonto integration is configured, the Null adapter otherwise (so callers
      # and UI degrade gracefully). No separate manual toggle — a configured
      # integration is the single source of truth.
      def build
        available? ? Adapters::Qonto.new : Adapters::Null.new
      end

      # Whether a usable Qonto e-invoicing gateway is configured for the tenant.
      def available?
        Integration.exists?(nature: 'qonto')
      rescue StandardError
        false
      end
    end

    # @return [Symbol] :enabled | :disabled | :pending | :unavailable
    def connection_status
      raise NotImplementedError
    end

    # @param entity [Entity]
    # @return [true, false, :unknown]
    def recipient_reachable?(_entity)
      raise NotImplementedError
    end

    # @param sale [Sale]
    # @return [Result] value = remote_id on success
    def submit(_sale)
      raise NotImplementedError
    end

    # @param remote_id [String]
    # @return [Array<Hash>] [{ code:, label:, occurred_at: }]
    def lifecycle(_remote_id)
      raise NotImplementedError
    end

    # @param datetime [Time]
    # @return [Array<Hash>] raw inbound invoices
    def inbound_since(_datetime)
      raise NotImplementedError
    end
  end
end
