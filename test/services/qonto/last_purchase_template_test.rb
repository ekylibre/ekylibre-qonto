# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_lettering'

class Qonto::LastPurchaseTemplateTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoLettering

  setup do
    @mode = outgoing_payment_modes(:outgoing_payment_modes_001)
    @cash = @mode.cash
    @supplier = entities(:entities_008)
    @tax = usable_taxes.first
    @rate = @tax.amount.to_d
  end

  def test_a_supplier_without_purchase_has_no_model
    without = Entity.where.not(id: PurchaseInvoice.select(:supplier_id)).first

    assert_nil Qonto::LastPurchaseTemplate.for(without, BigDecimal('50'))
  end

  def test_one_line_is_scaled_to_the_total
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME')

    model = Qonto::LastPurchaseTemplate.for(@supplier, BigDecimal('50'))

    assert_equal 1, model.items.size
    item = model.items.first
    assert_equal ProductNatureVariant.first.id, item[:variant_id]
    assert_equal @tax.id, item[:tax_id]
    assert_equal BigDecimal('50'), item[:amount]
    assert_equal (BigDecimal('50') / (1 + @rate / 100)).round(2), item[:unit_pretax_amount]
    assert_equal PurchaseNature.first.id, model.nature_id
  end

  def test_the_latest_purchase_is_the_model
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME', invoiced_at: Time.zone.local(2019, 9, 5))
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME', invoiced_at: Time.zone.local(2019, 10, 5))
    recent = @last_purchase

    assert_equal recent, Qonto::LastPurchaseTemplate.for(@supplier, BigDecimal('10')).purchase
  end

  def test_several_lines_keep_the_proportions_and_the_total
    second = usable_taxes.find { |t| t.amount != @tax.amount } || @tax
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME',
                      lines: [{ tax: @tax, unit_pretax_amount: 100 }, { tax: second, unit_pretax_amount: 300 }])

    model = Qonto::LastPurchaseTemplate.for(@supplier, BigDecimal('200'))

    assert_equal 2, model.items.size
    assert_equal BigDecimal('200'), model.items.sum { |i| i[:amount] }, 'the lines add up to what the bank paid'
    assert_operator model.items.last[:amount], :>, model.items.first[:amount]
  end

  def test_the_vat_split_given_by_qonto_makes_one_line_per_rate
    lettered_purchase(cash: @cash, mode: @mode, supplier: @supplier, label: 'ACME')
    split = [{ rate: @rate, amount: 4.0, amount_excluding_vat: 20.0 }, { rate: 0, amount: 0.0, amount_excluding_vat: 6.0 }]

    model = Qonto::LastPurchaseTemplate.for(@supplier, BigDecimal('30'), vat_details: split)

    assert_equal 2, model.items.size
    assert_equal [BigDecimal('24.0'), BigDecimal('6.0')], model.items.map { |i| i[:amount] }
    assert_equal [BigDecimal('20.0'), BigDecimal('6.0')], model.items.map { |i| i[:unit_pretax_amount] }
    assert_equal ProductNatureVariant.first.id, model.items.last[:variant_id], 'the article of the previous purchase is kept'
  end
end
