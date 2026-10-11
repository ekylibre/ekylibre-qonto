# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# An invoice issued by your own company that comes back through Qonto is a sale
# you already have, not a purchase.
class Qonto::OwnCompanyTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  SIRET = '12345678200019'
  SIREN = '123456782'
  VAT = 'FR12123456782'

  setup do
    @company = Entity.of_company
    @company.update_columns(siret_number: SIRET, vat_number: VAT)
    @own = Qonto::OwnCompany.new(@company)
  end

  def test_recognised_by_its_siret
    assert @own.issued?(doc(supplier_siret: SIRET))
  end

  def test_recognised_by_its_siren
    assert @own.issued?(doc(supplier_siret: SIREN))
  end

  def test_another_establishment_of_the_same_company_is_not_it
    # Same SIREN, different SIRET: a supplier that merely shares the company group.
    refute @own.issued?(doc(supplier_siret: '12345678200027'))
  end

  def test_recognised_by_its_vat_number_in_the_platform_payload_whatever_the_spacing
    assert @own.issued?(doc(payload: { vat_number: 'fr 12 123456782' }))
    assert @own.issued?(doc(payload: { seller: { vat_number: VAT } }))
  end

  def test_recognised_when_the_supplier_is_linked_to_the_company_entity
    assert @own.issued?(doc(entity: @company))
  end

  def test_another_supplier_is_not_it
    refute @own.issued?(doc(supplier_siret: '98765432100011', entity: entities(:entities_008), payload: { vat_number: 'FR99999999999' }))
  end

  def test_without_a_tax_id_nothing_is_assumed
    refute @own.issued?(doc)
  end

  def test_without_a_company_entity_nothing_is_flagged
    refute Qonto::OwnCompany.new(nil).issued?(doc(supplier_siret: SIRET))
  end

  def test_a_company_without_tax_ids_does_not_match_a_document_without_one
    @company.update_columns(siret_number: nil, vat_number: nil)

    refute Qonto::OwnCompany.new(@company.reload).issued?(doc(supplier_siret: ''))
  end

  def test_current_reads_the_company_of_the_tenant
    assert Qonto::OwnCompany.current.issued?(doc(supplier_siret: SIRET))
  end

  def test_finds_the_sale_a_document_is_the_copy_of
    sale = sales(:sales_001)

    assert_equal sale, @own.sale_for(doc(invoice_number: sale.number))
    assert_equal sale, @own.sale_for(doc(invoice_number: " #{sale.number[0, 2]}-#{sale.number[2..-1]} ".downcase))
    assert_nil @own.sale_for(doc(invoice_number: 'NO-SUCH-SALE'))
    assert_nil @own.sale_for(doc(invoice_number: nil))
  end

  private

    def doc(attrs = {})
      Qonto::InboundInvoice.new({ remote_id: SecureRandom.hex(4) }.merge(attrs))
    end
end
