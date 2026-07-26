# frozen_string_literal: true

module EInvoicing
  module Adapters
    # Qonto (Plateforme Agréée) implementation.
    #
    # This increment wires only the two safe, read-only lookups that exist
    # outside the e-invoicing network (which is production-only and cannot be
    # exercised in sandbox):
    #   - connection_status  → GET /v2/einvoicing/settings
    #   - recipient_reachable? → GET /v2/clients (e_invoicing_reachable)
    #
    # submit / lifecycle / inbound_since belong to later lots (emission &
    # reception) and raise NotImplementedError on purpose.
    class Qonto < Gateway
      def connection_status
        body = call_settings
        return :unavailable if body.nil?

        case body[:receiving_status].to_s
        when 'enabled'                          then :enabled
        when 'pending_creation', 'pending_deletion' then :pending
        when 'disabled'                         then :disabled
        else :unavailable
        end
      end

      def recipient_reachable?(entity)
        return :unknown if entity.nil?

        client = find_client(entity)
        return :unknown if client.nil?

        !!client[:e_invoicing_reachable]
      end

      def submit(_sale)
        raise NotImplementedError, 'EInvoicing::Adapters::Qonto#submit — emission (lot 3)'
      end

      def lifecycle(_remote_id)
        raise NotImplementedError, 'EInvoicing::Adapters::Qonto#lifecycle — emission (lot 3)'
      end

      # Reception — GET /v2/supplier_invoices. Returns normalized invoices
      # (regulatory vocabulary), keeping the raw Qonto payload for replayability.
      def inbound_since(datetime = nil)
        body = call_supplier_invoices(datetime)
        return [] if body.nil?

        Array(body[:supplier_invoices]).map { |raw| normalize_inbound(raw) }
      end

      private

        def call_settings
          ::Qonto::QontoIntegration.einvoicing_settings.execute do |c|
            c.success { |body| body }
          end
        rescue StandardError => e
          Rails.logger.warn("[Qonto][einvoicing] settings failed: #{e.class}: #{e.message}")
          nil
        end

        def call_clients
          ::Qonto::QontoIntegration.list_clients.execute do |c|
            c.success { |body| body }
          end
        rescue StandardError => e
          Rails.logger.warn("[Qonto][einvoicing] clients failed: #{e.class}: #{e.message}")
          nil
        end

        def call_supplier_invoices(datetime)
          from = datetime.respond_to?(:utc) ? datetime.utc.iso8601 : datetime
          ::Qonto::QontoIntegration.list_supplier_invoices(from).execute do |c|
            c.success { |body| body }
          end
        rescue StandardError => e
          Rails.logger.warn("[Qonto][einvoicing] supplier_invoices failed: #{e.class}: #{e.message}")
          nil
        end

        # Tolerant mapping from the raw Qonto supplier-invoice payload to the
        # gateway's regulatory shape. Unknown/renamed fields degrade to nil
        # rather than raising — the raw payload is kept under :payload.
        def normalize_inbound(raw)
          total = raw[:total_amount] || {}
          {
            remote_id: raw[:id].to_s,
            supplier_name: raw[:supplier_name] || raw.dig(:supplier, :name),
            supplier_siret: raw[:supplier_siret] || raw.dig(:supplier, :tax_identification_number),
            invoice_number: raw[:invoice_number] || raw[:number],
            currency: total[:currency] || raw[:currency],
            amount: (total[:value] || raw[:total_amount_value] || raw[:amount])&.to_d,
            pretax_amount: (raw[:total_amount_excluding_vat] || raw[:pretax_amount])&.to_d,
            issued_on: safe_date(raw[:issue_date] || raw[:issued_on]),
            due_on: safe_date(raw[:due_date] || raw[:due_on]),
            file_url: raw[:file_url] || raw[:pdf_url] || raw.dig(:attachment, :url) || raw.dig(:file, :url),
            file_name: raw[:file_name] || raw.dig(:attachment, :file_name) || raw.dig(:attachment, :name),
            lines: normalize_lines(raw),
            payload: raw
          }
        end

        def safe_date(value)
          return nil if value.blank?

          value.to_date
        rescue ArgumentError, TypeError
          nil
        end

        # Normalized (PA-agnostic) invoice lines. Values are kept as plain
        # numbers/strings so they round-trip cleanly through jsonb; conversion
        # to BigDecimal happens when a PurchaseItem is built.
        def normalize_lines(raw)
          rows = raw[:line_items] || raw[:items] || raw[:lines] || []
          Array(rows).map do |l|
            {
              label: l[:description] || l[:label] || l[:name],
              quantity: l[:quantity] || l[:qty],
              unit_pretax_amount: l[:unit_price] || l[:unit_pretax_amount] || l[:unit_amount],
              vat_rate: l[:vat_rate] || l[:vat_rate_percentage] || l[:tax_rate]
            }
          end
        end

        # Matches an Ekylibre Entity to a Qonto client, by SIRET first (the
        # routing key in the DGFiP directory), then by email.
        def find_client(entity)
          body = call_clients
          return nil if body.nil?

          clients = Array(body[:clients])

          siret = entity.respond_to?(:siret_number) ? entity.siret_number : nil
          if siret.present?
            by_siret = clients.find { |c| c[:tax_identification_number].to_s == siret.to_s }
            return by_siret if by_siret
          end

          email = entity.respond_to?(:email) ? entity.email : nil
          return nil if email.blank?

          clients.find { |c| c[:email].to_s.casecmp(email.to_s).zero? }
        end
    end
  end
end
