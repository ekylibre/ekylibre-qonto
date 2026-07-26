# frozen_string_literal: true

module EInvoicing
  module Adapters
    # No-op adapter for tenants without a Qonto integration. Everything degrades
    # gracefully — never raises, never calls the network — so the UI can render a
    # disabled/absent state.
    class Null < Gateway
      def connection_status
        :unavailable
      end

      def recipient_reachable?(_entity)
        :unknown
      end

      def submit(_sale)
        Result.failure(:not_configured, 'No e-invoicing integration for this tenant')
      end

      def lifecycle(_remote_id)
        []
      end

      def inbound_since(_datetime)
        []
      end
    end
  end
end
