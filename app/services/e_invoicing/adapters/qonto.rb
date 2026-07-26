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
      # Idempotency link stored on the Entity's `provider` jsonb: an Ekylibre
      # organization maps to exactly one Qonto client, so we never create a
      # duplicate on re-emission.
      CLIENT_PROVIDER_VENDOR = 'qonto'
      CLIENT_PROVIDER_NAME = 'client'

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

      # Emission — resolve (find-or-create) the Qonto client, create the client
      # invoice referencing its client_id, then request e-invoice sending.
      # Production only (no sandbox e-invoicing); the state machine is covered by
      # the Fake adapter in tests.
      def submit(sale)
        # Cheap local prerequisite first, before any network round-trip.
        iban = organization_iban
        return Result.failure('missing_iban', 'No bank account IBAN to receive the payment') if iban.blank?

        client_id = resolve_client_id(sale.client)
        return Result.failure('client_unresolved', 'Could not find or create the Qonto client') if client_id.blank?

        payload = ::Qonto::ClientInvoicePayload.build(sale, client_id: client_id, iban: iban)
        created = execute_result(::Qonto::QontoIntegration.create_client_invoice(payload))
        remote_id = extract_id(created, :client_invoice)
        return Result.failure('create_failed', error_detail(created)) if remote_id.blank?

        sent = execute_result(::Qonto::QontoIntegration.send_client_invoice(remote_id))
        return Result.success(remote_id.to_s) if sent == true

        Result.failure(error_code(sent), error_detail(sent))
      rescue StandardError => e
        Rails.logger.warn("[Qonto][einvoicing] submit failed: #{e.class}: #{e.message}")
        Result.failure('submit_failed', e.message)
      end

      def lifecycle(remote_id)
        body = execute_result(::Qonto::QontoIntegration.get_client_invoice(remote_id))
        invoice = unwrap(body, :client_invoice)
        return [] if invoice.empty?

        Array(invoice[:einvoicing_lifecycle_events]).map do |ev|
          {
            code: (ev[:status_code] || ev[:code]).to_s,
            label: ev[:reason_message] || ev[:reason] || ev[:label] || ev[:status],
            occurred_at: ev[:timestamp] || ev[:occurred_at] || ev[:created_at]
          }
        end
      rescue StandardError => e
        Rails.logger.warn("[Qonto][einvoicing] lifecycle failed: #{e.class}: #{e.message}")
        []
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

        # Runs a Call and captures the success body (or the error body wrapped in
        # { error: ... }) into a plain return value.
        def execute_result(call)
          captured = nil
          call.execute do |c|
            c.success { |body| captured = body }
            c.error   { |body| captured = { error: body } }
          end
          captured
        end

        # Qonto wraps a single resource under its singular key
        # ({ "client": {...} }, { "client_invoice": {...} }). Unwrap tolerantly:
        # fall back to the body itself when the key is absent (e.g. error bodies).
        def unwrap(body, key)
          return {} unless body.is_a?(Hash)

          inner = body[key]
          inner.is_a?(Hash) ? inner : body
        end

        def extract_id(body, key)
          unwrap(body, key)[:id]
        end

        def error_code(obj)
          return 'error' unless obj.is_a?(Hash)

          source = obj[:error].is_a?(Hash) ? obj[:error] : obj
          (source[:code] || source.dig(:errors, 0, :code) || 'error').to_s
        end

        def error_detail(obj)
          return obj.to_s unless obj.is_a?(Hash)

          source = obj[:error].is_a?(Hash) ? obj[:error] : obj
          (source[:detail] || source[:message] || source.dig(:errors, 0, :detail)).to_s
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

        # Returns the Qonto client_id for an Ekylibre Entity, idempotently:
        #   1. a link already stored on the entity's provider → no network call;
        #   2. else a Qonto client matched by SIRET/VAT/email → link and reuse;
        #   3. else create the client → link and return.
        # Steps 2 & 3 persist the id so the next emission takes the fast path and
        # no duplicate client is ever created.
        def resolve_client_id(entity)
          return nil if entity.nil?

          linked = linked_client_id(entity)
          return linked if linked.present?

          existing = find_client(entity)
          if existing && existing[:id].present?
            link_client!(entity, existing[:id])
            return existing[:id].to_s
          end

          created = execute_result(::Qonto::QontoIntegration.create_client(::Qonto::ClientPayload.build(entity)))
          id = extract_id(created, :client)
          return nil if id.blank?

          link_client!(entity, id)
          id.to_s
        end

        # The Qonto client_id previously stored on the entity, if any.
        def linked_client_id(entity)
          return nil unless entity.respond_to?(:is_provided_by?)
          return nil unless entity.is_provided_by?(vendor: CLIENT_PROVIDER_VENDOR, name: CLIENT_PROVIDER_NAME)

          entity.provider_id.presence
        end

        # Persists the Qonto client_id on the entity's provider slot. That slot is
        # single-vendor and may already be owned by an importer (Socleo, FEC, …);
        # we never clobber another vendor — those entities just re-resolve over
        # the network (still correct, only not cached).
        def link_client!(entity, id)
          return unless entity.respond_to?(:update_columns) && entity.try(:persisted?)
          return if entity.try(:provider).present? && !entity.is_provided_by?(vendor: CLIENT_PROVIDER_VENDOR, name: CLIENT_PROVIDER_NAME)

          entity.update_columns(provider: { vendor: CLIENT_PROVIDER_VENDOR, name: CLIENT_PROVIDER_NAME, id: id.to_s })
        rescue StandardError => e
          Rails.logger.warn("[Qonto][einvoicing] could not persist client link: #{e.class}: #{e.message}")
        end

        # Matches an Ekylibre Entity to a Qonto client, by SIRET first (the
        # routing key in the DGFiP directory), then VAT number, then email.
        def find_client(entity)
          body = call_clients
          return nil if body.nil?

          clients = Array(body[:clients])

          siret = entity.try(:siret_number)
          if siret.present?
            by_siret = clients.find { |c| c[:tax_identification_number].to_s == siret.to_s }
            return by_siret if by_siret
          end

          vat = entity.try(:vat_number)
          if vat.present?
            by_vat = clients.find { |c| c[:vat_number].to_s == vat.to_s }
            return by_vat if by_vat
          end

          email = entity_email(entity)
          return nil if email.blank?

          clients.find { |c| c[:email].to_s.casecmp(email.to_s).zero? }
        end

        def entity_email(entity)
          entity.emails.first&.coordinate if entity.respond_to?(:emails)
        rescue StandardError
          nil
        end

        # The seller IBAN carried by payment_methods.iban. Prefer a Qonto-provided
        # bank account, else any bank account with an IBAN.
        def organization_iban
          scope = ::Cash.bank_accounts.where.not(iban: [nil, ''])
          scope.of_provider_vendor('qonto').first&.iban || scope.first&.iban
        end
    end
  end
end
