# frozen_string_literal: true

require 'test_helper'

class Qonto::MandatoryMentionsTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  # A sale line, minimally, is anything that answers #variant.
  Line = Struct.new(:variant)

  setup do
    @sale = sales(:sales_001)
    @sale.update_columns(delivery_address_id: nil)
    @sale.client.update_columns(siret_number: nil)
    @goods_variant = ProductNatureVariant.find(9)    # straw → article → goods
    @service_variant = ProductNatureVariant.find(70)  # immatter → service → services
  end

  def test_lists_every_missing_mention
    # Bare sale, no VAT regime set up and no derivable line.
    @sale.stub(:items, []) do
      with_current_financial_year(nil) do
        missing = Qonto::MandatoryMentions.new(@sale).missing
        assert_equal %i[client_siren delivery_address operation_category vat_payment_option].sort, missing.sort
        refute Qonto::MandatoryMentions.new(@sale).complete?
      end
    end
  end

  def test_complete_when_all_present
    fill_identity
    with_declared_financial_year do
      assert Qonto::MandatoryMentions.new(@sale).complete?
    end
  end

  # --- operation category derived from the lines -------------------------------

  def test_derives_goods_from_goods_only_lines
    @sale.stub(:items, [Line.new(@goods_variant)]) do
      assert_equal 'goods', Qonto::MandatoryMentions.new(@sale).operation_category
    end
  end

  def test_derives_services_from_service_only_lines
    @sale.stub(:items, [Line.new(@service_variant)]) do
      assert_equal 'services', Qonto::MandatoryMentions.new(@sale).operation_category
    end
  end

  def test_derives_mixed_when_lines_mix_goods_and_services
    @sale.stub(:items, [Line.new(@goods_variant), Line.new(@service_variant)]) do
      assert_equal 'mixed', Qonto::MandatoryMentions.new(@sale).operation_category
    end
  end

  def test_operation_category_missing_without_any_line
    fill_identity
    @sale.stub(:items, []) do
      with_declared_financial_year do
        assert_nil Qonto::MandatoryMentions.new(@sale).operation_category
        assert_equal [:operation_category], Qonto::MandatoryMentions.new(@sale).missing
      end
    end
  end

  # --- VAT option read off the current financial year -------------------------

  def test_vat_option_missing_when_regime_not_set_up
    fill_identity
    with_current_financial_year(FinancialYear.new(tax_declaration_mode: 'none')) do
      assert_equal [:vat_payment_option], Qonto::MandatoryMentions.new(@sale).missing
    end
  end

  def test_vat_option_satisfied_on_debits
    fill_identity
    with_current_financial_year(FinancialYear.new(tax_declaration_mode: 'debit')) do
      refute_includes Qonto::MandatoryMentions.new(@sale).missing, :vat_payment_option
    end
  end

  def test_vat_option_missing_without_any_financial_year
    fill_identity
    with_current_financial_year(nil) do
      assert_equal [:vat_payment_option], Qonto::MandatoryMentions.new(@sale).missing
    end
  end

  private

    # SIRET on the client + a delivery address; leaves lines and VAT to the caller.
    def fill_identity
      @sale.client.update_columns(siret_number: '12369874500015')
      @sale.update_columns(delivery_address_id: EntityAddress.first.id)
    end

    def with_current_financial_year(fy)
      FinancialYear.stub(:current, fy) { yield }
    end

    def with_declared_financial_year(&block)
      with_current_financial_year(FinancialYear.new(tax_declaration_mode: 'payment'), &block)
    end
end
