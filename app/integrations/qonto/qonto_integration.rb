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

    authenticate_with :check do
      parameter :client_id
      parameter :client_secret
    end

    calls :list_transactions, :show_attachment

    def check(integration = nil)
      integration = fetch integration
      get_json(BASE_URL + "/organizations/#{integration.parameters['client_id']}", authentication_header(integration)) do |r|
        r.success do
          puts 'check success'.inspect.green
        end
      end
    end

    # https://api-doc.qonto.com/docs/business-api/2c89e53f7f645-list-transactions
    def list_transactions(iban)
      integration = fetch integration
      get_json(BASE_URL + "/transactions?iban=#{iban}", authentication_header(integration)) do |r|
        r.success do
          puts 'check success'.inspect.green
          list = JSON(r.body).deep_symbolize_keys
        end
      end
    end

    # https://api-doc.qonto.com/docs/business-api/345dace7b485b-show-attachment
    def show_attachment(id)
      integration = fetch integration
      get_json(BASE_URL + "/attachments/#{id}", authentication_header(integration)) do |r|
        r.success do
          puts 'check success'.inspect.green
          list = JSON(r.body).deep_symbolize_keys
        end
      end
    end

    private

    def authentication_header(integration)
      string_to_encode = "#{integration.parameters['client_id']}:#{integration.parameters['client_secret']}"
      { authorization: "#{string_to_encode}", 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
    end

  end
end
