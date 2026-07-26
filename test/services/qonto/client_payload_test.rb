# frozen_string_literal: true

require 'test_helper'
require 'securerandom'

class Qonto::ClientPayloadTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  # Minimal stand-ins for the mail address / email coordinates.
  Addr = Struct.new(:mail_line_4, :mail_postal_code, :mail_mail_line_6_city, :mail_country)
  Email = Struct.new(:coordinate)

  def test_company_mapping_with_address
    org = build_entity(nature: 'organization', last_name: 'ACME')
    org.update_columns(siret_number: '12369874500015', vat_number: 'FR40303265045')
    addr = Addr.new('12 rue des Champs', '75008', 'Paris', 'fr')

    payload = nil
    org.stub(:default_mail_address, addr) do
      org.stub(:emails, [Email.new('contact@acme.test')]) do
        payload = Qonto::ClientPayload.build(org)
      end
    end

    assert_equal 'company', payload[:kind]
    assert_equal org.full_name, payload[:name]
    assert_equal 'EUR', payload[:currency]
    assert_equal 'FR', payload[:locale]
    assert_equal '12369874500015', payload[:tax_identification_number]
    assert_equal 'FR40303265045', payload[:vat_number]
    assert_equal 'contact@acme.test', payload[:email]
    assert_equal '12 rue des Champs', payload[:address]
    assert_equal '75008', payload[:zip_code]
    assert_equal 'Paris', payload[:city]
    assert_equal 'FR', payload[:country_code]
    refute payload.key?(:first_name)
  end

  def test_individual_mapping_and_missing_address
    person = build_entity(nature: 'contact', first_name: 'Jean', last_name: 'Bon', language: 'eng')

    payload = nil
    person.stub(:emails, []) do
      payload = Qonto::ClientPayload.build(person) # fresh entity → no default_mail_address
    end

    assert_equal 'individual', payload[:kind]
    assert_equal 'Jean', payload[:first_name]
    assert_equal 'Bon', payload[:last_name]
    assert_equal 'EN', payload[:locale]
    refute payload.key?(:name)
    refute payload.key?(:address), 'no address fields when the entity has none'
  end

  private

    def build_entity(attrs)
      Entity.create!({
        country: 'fr', currency: 'EUR', language: 'fra',
        last_name: "E-#{SecureRandom.hex(4)}"
      }.merge(attrs))
    end
end
