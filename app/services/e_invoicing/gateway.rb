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
    # @param remote_id [String, nil] the invoice already created on the platform
    #   by an earlier attempt that failed afterwards: it is sent, never created
    #   again (a second draft would be a second invoice for the same sale).
    # @param on_created [#call, nil] called with the remote id as soon as the
    #   platform has created the invoice, before it is sent, so a failure of
    #   the sending still leaves the caller knowing which invoice it is.
    # @return [Result] value = remote_id on success
    def submit(_sale, remote_id: nil, on_created: nil)
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

    # Resolves the downloadable file of a received document. The inbound list
    # only carries ids; the (short-lived) URL has to be asked for.
    # @param id [String] attachment id
    # @return [Hash, nil] { url:, content_type:, file_name:, size: }
    def attachment(_id)
      raise NotImplementedError
    end
  end
end
