# frozen_string_literal: true

module Qonto
  # Pulls the PA lifecycle for a submitted invoice and advances the local status
  # (submitted → issued → received) from the highest reached status_code. Records
  # the events mirror, timestamps and poll bookkeeping for the audit trail.
  class RefreshEInvoiceService
    def self.call(outbound)
      new(outbound).call
    end

    def initialize(outbound)
      @outbound = outbound
    end

    # @return [OutboundInvoice]
    def call
      return @outbound if @outbound.remote_id.blank?

      events = normalize(EInvoicing::Gateway.build.lifecycle(@outbound.remote_id))
      status = status_from(events) || @outbound.status

      attrs = {
        lifecycle_events: events,
        status: status,
        last_polled_at: Time.zone.now,
        poll_attempts: @outbound.poll_attempts + 1
      }
      attrs[:issued_at]   = Time.zone.now if status == 'issued'   && @outbound.issued_at.nil?
      attrs[:received_at] = Time.zone.now if status == 'received' && @outbound.received_at.nil?

      @outbound.update!(attrs)
      @outbound
    end

    private

      # Normalize to string keys so the mirror round-trips through jsonb.
      def normalize(events)
        Array(events).map { |e| e.transform_keys(&:to_s) }
      end

      def status_from(events)
        codes = events.map { |e| e['code'].to_s }
        OutboundInvoice::STEPS.reverse_each do |step|
          return step[:status] if codes.include?(step[:code])
        end
        nil
      end
  end
end
