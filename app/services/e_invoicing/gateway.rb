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

    # Per-tenant feature flag (Q-C): the gateway is opt-in per tenant.
    FEATURE_FLAG = :qonto_einvoicing_enabled

    class << self
      # Selects the adapter for the current tenant. Falls back to the Null
      # adapter (never raises) when the feature is off or no integration exists,
      # so callers/UI degrade gracefully.
      def build
        return Adapters::Null.new unless enabled? && integration_present?

        Adapters::Qonto.new
      end

      def enabled?
        # Custom (non-predefined) preference: read the row directly, since
        # Preference[] only accepts preferences declared in the core reference.
        !!Preference.find_by(name: FEATURE_FLAG.to_s)&.value
      rescue StandardError
        false
      end

      private

        def integration_present?
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
