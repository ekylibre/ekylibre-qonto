# frozen_string_literal: true

module EInvoicing
  module Adapters
    # Deterministic in-memory adapter for tests & staging, since Qonto
    # e-invoicing does not exist in sandbox. Reproduces the nominal lifecycle
    # 200 → 201 → 202 (déposée → émise → reçue) and the main failure paths
    # (recipient not reachable, out-of-sequence progression on unknown ids).
    #
    # `occurred_at` is a monotonic integer tick rather than a wall-clock time so
    # assertions stay deterministic without a real clock.
    class Fake < Gateway
      STEPS = [
        { code: '200', label: 'deposited' },
        { code: '201', label: 'issued' },
        { code: '202', label: 'received' }
      ].freeze

      # @param connection [Symbol] value returned by #connection_status
      # @param reachable [true, false, :unknown, Hash] reachability, globally or
      #   per entity id
      def initialize(connection: :enabled, reachable: true)
        @connection = connection
        @reachable = reachable
        @invoices = {}
        @inbound = []
        @seq = 0
        @tick = 0
      end

      def connection_status
        @connection
      end

      def recipient_reachable?(entity)
        return @reachable unless @reachable.is_a?(Hash)

        @reachable.fetch(entity_key(entity), :unknown)
      end

      # Happy path → Result(remote_id) and records the first lifecycle event.
      # Unreachable recipient → regulatory 412 failure, no invoice created.
      def submit(sale)
        recipient = sale.respond_to?(:client) ? sale.client : nil
        unless recipient_reachable?(recipient) == true
          return Result.failure('recipient_not_reachable_on_einvoicing')
        end

        @seq += 1
        remote_id = "fake-einvoice-#{@seq}"
        @invoices[remote_id] = { events: [event(STEPS.first)] }
        Result.success(remote_id)
      end

      # Simulates the PA / webhook pushing the invoice to its next state.
      # @return [Array<Hash>, nil] current lifecycle, or nil for an unknown id.
      def advance(remote_id)
        record = @invoices[remote_id]
        return nil if record.nil?

        next_step = STEPS[record[:events].size]
        record[:events] << event(next_step) if next_step
        record[:events].dup
      end

      def lifecycle(remote_id)
        record = @invoices[remote_id]
        record ? record[:events].dup : []
      end

      def inbound_since(datetime = nil)
        return @inbound.dup if datetime.nil?

        @inbound.select { |i| i[:updated_at].nil? || i[:updated_at] >= datetime }
      end

      # Test/staging helper: preload inbound invoices.
      def stub_inbound(list)
        @inbound = Array(list)
        self
      end

      private

        def event(step)
          @tick += 1
          { code: step[:code], label: step[:label], occurred_at: @tick }
        end

        def entity_key(entity)
          entity.respond_to?(:id) ? entity.id : entity
        end
    end
  end
end
