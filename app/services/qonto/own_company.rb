# frozen_string_literal: true

module Qonto
  # A document "received" from your own company is an invoice you issued: it
  # came back through the bank documents, it is not a purchase. Booking it as
  # one would count the same sale as an expense.
  #
  # Recognised by the company's SIREN or SIRET, its VAT number, or an inbox
  # supplier already linked to the company entity.
  class OwnCompany
    # @param entity [Entity, nil] the company of the tenant
    def self.current
      new(Entity.of_company)
    rescue StandardError
      new(nil)
    end

    def initialize(entity)
      @entity = entity
      @siret = digits(entity&.siret_number)
      @siren = @siret.first(9)
      @vat = squash(entity&.vat_number)
    end

    def issued?(inbound)
      return false if @entity.nil?
      return true if inbound.entity_id == @entity.id

      tax_id = digits(inbound.supplier_siret)
      return true if tax_id.size == 14 && @siret.size == 14 && tax_id == @siret
      return true if tax_id.size == 9 && @siren.size == 9 && tax_id == @siren

      vat = squash(vat_in(inbound.payload))
      vat.present? && @vat.present? && vat == @vat
    end

    # The sale this document is the copy of, when it carries that number.
    # @return [Sale, nil]
    def sale_for(inbound)
      number = inbound.invoice_number.to_s.strip
      return nil if number.blank?

      Sale.find_by(number: number) ||
        Sale.where("#{Reference.sql('number')} = ?", Reference.normalize(number)).first
    end

    private

      def vat_in(payload)
        data = payload.to_h.deep_stringify_keys
        data['vat_number'] || data.dig('seller', 'vat_number')
      end

      def digits(value)
        value.to_s.gsub(/\D/, '')
      end

      def squash(value)
        value.to_s.upcase.gsub(/\s/, '')
      end
  end
end
