# frozen_string_literal: true

module Qonto
  # Maps an Ekylibre Entity to the Qonto "create a client" payload
  # (POST /v2/clients). A client must exist in Qonto before a client_invoice can
  # reference it, and for invoicing Qonto also requires currency, locale and an
  # address. Kept tolerant (compact) so a missing optional field is dropped
  # rather than raising — the API validates the final shape.
  class ClientPayload
    # Ekylibre 3-letter language → Qonto locale enum.
    LOCALES = { 'fra' => 'FR', 'eng' => 'EN', 'ita' => 'IT', 'deu' => 'DE', 'spa' => 'ES' }.freeze

    def self.build(entity)
      new(entity).to_h
    end

    def initialize(entity)
      @entity = entity
    end

    def to_h
      {
        kind: kind,
        currency: @entity.currency,
        locale: locale,
        email: email,
        tax_identification_number: siret,
        vat_number: vat_number
      }.merge(name_fields).merge(address_fields).compact
    end

    private

      # Qonto kinds: company | freelancer | individual. Ekylibre only splits
      # organization vs contact, so an organization maps to "company".
      def kind
        @entity.organization? ? 'company' : 'individual'
      end

      def name_fields
        if @entity.organization?
          { name: @entity.full_name }
        else
          { first_name: @entity.first_name.presence || @entity.full_name,
            last_name: @entity.last_name }
        end
      end

      def locale
        LOCALES[@entity.language.to_s] || 'FR'
      end

      def email
        @entity.emails.first&.coordinate
      rescue StandardError
        nil
      end

      def siret
        @entity.try(:siret_number)
      end

      def vat_number
        @entity.try(:vat_number)
      end

      # French postal layout: mail_line_4 is the street, the postal zone carries
      # zip + city, mail_country the ISO code.
      def address_fields
        address = @entity.default_mail_address
        return {} if address.nil?

        {
          address: address.mail_line_4.presence,
          zip_code: zip_code(address),
          city: city(address),
          country_code: address.mail_country&.upcase
        }.compact
      end

      def zip_code(address)
        address.mail_postal_code.presence
      rescue StandardError
        nil
      end

      def city(address)
        address.mail_mail_line_6_city.presence
      rescue StandardError
        nil
      end
  end
end
