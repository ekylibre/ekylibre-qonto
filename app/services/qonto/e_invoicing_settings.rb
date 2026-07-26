# frozen_string_literal: true

module Qonto
  # Connection state for the e-invoicing compliance banner (S1).
  #
  # As soon as a Qonto integration exists, the real reception state is read from
  # the API (GET /v2/einvoicing/settings) so the banner reflects the account's
  # actual status — not a manual flag. The result is cached (default 1h) so the
  # API call happens at most once per TTL, never on every page render. Without an
  # integration, reception is simply not set up.
  class EInvoicingSettings
    CACHE_KEY = 'qonto:einvoicing:connection_status'
    CACHE_TTL = 1.hour

    class << self
      def cached
        new(Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute })
      end

      # Called by the hourly job (background) to keep the cache warm.
      def refresh!
        status = compute
        Rails.cache.write(cache_key, status, expires_in: CACHE_TTL)
        status
      end

      def cache_key
        "#{CACHE_KEY}:#{Ekylibre::Tenant.current}"
      end

      private

        def compute
          return :unavailable unless integration?

          # Real API check. A transient API failure returns :unavailable from the
          # adapter — treat that as :unknown so a network blip does not raise a
          # false "not connected" alarm on a configured tenant.
          status = EInvoicing::Adapters::Qonto.new.connection_status
          status == :unavailable ? :unknown : status
        end

        def integration?
          Integration.exists?(nature: 'qonto')
        rescue StandardError
          false
        end
    end

    def initialize(status)
      @status = status
    end

    attr_reader :status

    def enabled?
      status == :enabled
    end

    def pending?
      status == :pending
    end

    # A tenant that must act: reception not established (no integration, or the
    # PA reports it disabled). :unknown / :enabled / :pending never trip this.
    def receiving_disabled?
      %i[disabled unavailable].include?(status)
    end
  end
end
