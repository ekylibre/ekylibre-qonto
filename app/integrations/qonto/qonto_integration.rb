require 'rest-client'

module Qonto
  mattr_reader :default_options do
    {
      globals: {
        strip_namespaces: true,
        convert_response_tags_to: ->(tag) { tag.snakecase.to_sym },
        raise_errors: true
      },
      locals: {
        advanced_typecasting: true
      }
    }
  end

  class ServiceError < StandardError; end

  class QontoIntegration < ActionIntegration::Base

    BASE_URL = 'https://thirdparty.qonto.com/v2'.freeze
    # Max page size accepted by the Qonto Business API.
    PER_PAGE = 100

    authenticate_with :check do
      parameter :client_id
      parameter :client_secret
    end

    calls :list_transactions, :show_attachment, :get_organization, :einvoicing_settings, :list_clients, :create_client, :list_supplier_invoices,
          :create_client_invoice, :send_client_invoice, :get_client_invoice

    # Connection check.
    # Uses GET /v2/organization (the authenticated organization) instead of the
    # deprecated GET /v2/organizations/{id} (sunset 2026-11-15, and which
    # additionally received the client_id where a slug was expected).
    def check(integration = nil)
      integration = fetch integration
      get_json("#{BASE_URL}/organization", authentication_header(integration)) do |r|
        r.success do
          Rails.logger.info('[Qonto] connection check succeeded')
        end
      end
    end

    def get_organization
      integration = fetch
      get_json("#{BASE_URL}/organization", authentication_header(integration)) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end
      end
    end

    # https://api-doc.qonto.com/docs/business-api/2c89e53f7f645-list-transactions
    # Follows the Qonto pagination (meta.next_page) so no page is silently lost.
    def list_transactions(iban)
      integration = fetch
      all_transactions = []
      current_page = 1
      response = nil

      loop do
        next_page = nil
        url = "#{BASE_URL}/transactions?iban=#{iban}&current_page=#{current_page}&per_page=#{PER_PAGE}"
        response = get_json(url, authentication_header(integration)) do |r|
          r.success do
            body = JSON(r.body).deep_symbolize_keys
            all_transactions.concat(Array(body[:transactions]))
            next_page = body.dig(:meta, :next_page)
            { transactions: all_transactions, meta: body[:meta] }
          end
        end

        # Stop on the last page, or as soon as a request is not successful
        # (next_page stays nil when the success block did not run).
        break if next_page.nil?

        current_page = next_page
      end

      response
    end

    # https://api-doc.qonto.com/docs/business-api/345dace7b485b-show-attachment
    def show_attachment(id)
      integration = fetch
      get_json("#{BASE_URL}/attachments/#{id}", authentication_header(integration)) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end
      end
    end

    # E-invoicing settings — GET /v2/einvoicing/settings
    # => { sending_status, receiving_status }
    def einvoicing_settings
      integration = fetch
      get_json("#{BASE_URL}/einvoicing/settings", authentication_header(integration)) do |r|
        r.success do
          JSON(r.body).deep_symbolize_keys
        end
      end
    end

    # Clients — GET /v2/clients (paginated). Carries e_invoicing_reachable,
    # the prerequisite before submitting an e-invoice to a recipient.
    def list_clients
      integration = fetch
      all_clients = []
      current_page = 1
      response = nil

      loop do
        next_page = nil
        url = "#{BASE_URL}/clients?current_page=#{current_page}&per_page=#{PER_PAGE}"
        response = get_json(url, authentication_header(integration)) do |r|
          r.success do
            body = JSON(r.body).deep_symbolize_keys
            all_clients.concat(Array(body[:clients]))
            next_page = body.dig(:meta, :next_page)
            { clients: all_clients, meta: body[:meta] }
          end
        end

        break if next_page.nil?

        current_page = next_page
      end

      response
    end

    # Clients — POST /v2/clients. Qonto requires the client to pre-exist before
    # a client_invoice can reference it (client_id is mandatory), so emission
    # resolves the client and creates it here when missing.
    def create_client(payload)
      integration = fetch
      post_json("#{BASE_URL}/clients", payload, authentication_header(integration)) do |r|
        r.success { JSON(r.body).deep_symbolize_keys }
        r.error   { safe_json(r.body) }
      end
    end

    # Supplier invoices — GET /v2/supplier_invoices (RECEPTION, paginated).
    # @param updated_at_from [String, nil] ISO8601 lower bound to only pull the
    #   invoices changed since the last sync.
    def list_supplier_invoices(updated_at_from = nil)
      integration = fetch
      all_invoices = []
      current_page = 1
      response = nil

      loop do
        next_page = nil
        url = "#{BASE_URL}/supplier_invoices?current_page=#{current_page}&per_page=#{PER_PAGE}"
        url += "&filter[updated_at_from]=#{updated_at_from}" if updated_at_from.present?
        response = get_json(url, authentication_header(integration)) do |r|
          r.success do
            body = JSON(r.body).deep_symbolize_keys
            all_invoices.concat(Array(body[:supplier_invoices]))
            next_page = body.dig(:meta, :next_page)
            { supplier_invoices: all_invoices, meta: body[:meta] }
          end
        end

        break if next_page.nil?

        current_page = next_page
      end

      response
    end

    # Emission (client invoices) — production only (no sandbox e-invoicing).
    # POST /v2/client_invoices
    def create_client_invoice(payload)
      integration = fetch
      post_json("#{BASE_URL}/client_invoices", payload, authentication_header(integration)) do |r|
        r.success { JSON(r.body).deep_symbolize_keys }
        r.error   { safe_json(r.body) }
      end
    end

    # POST /v2/client_invoices/{id}/send_by_einvoice → 204 accepted for processing
    def send_client_invoice(id)
      integration = fetch
      post_json("#{BASE_URL}/client_invoices/#{id}/send_by_einvoice", {}, authentication_header(integration)) do |r|
        r.success { true }
        r.error   { safe_json(r.body) }
      end
    end

    # GET /v2/client_invoices/{id} → einvoicing_status + einvoicing_lifecycle_events[]
    def get_client_invoice(id)
      integration = fetch
      get_json("#{BASE_URL}/client_invoices/#{id}", authentication_header(integration)) do |r|
        r.success { JSON(r.body).deep_symbolize_keys }
      end
    end

    private

      def safe_json(body)
        JSON(body).deep_symbolize_keys
      rescue StandardError
        {}
      end

      def authentication_header(integration)
        login = "#{integration.parameters['client_id']}:#{integration.parameters['client_secret']}"
        { authorization: login, 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
      end

  end
end
