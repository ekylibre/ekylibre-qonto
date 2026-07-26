# frozen_string_literal: true

require 'test_helper'

class Qonto::PurchaseFromInboundInvoiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008)
    # issued_on within an opened fixture financial year (2019-09 → 2020-08)
    @inbound = Qonto::InboundInvoice.create!(
      remote_id: 'p-1', entity: @supplier, invoice_number: 'FA-9',
      currency: 'EUR', issued_on: Date.new(2019, 10, 15), amount: 100, pretax_amount: 100
    )
  end

  def test_creates_linked_draft_purchase_and_marks_matched
    purchase = nil
    assert_difference 'PurchaseInvoice.count', 1 do
      purchase = Qonto::PurchaseFromInboundInvoice.call(@inbound)
    end

    assert_equal @supplier.id, purchase.supplier_id
    assert_equal 'FA-9', purchase.reference_number
    assert_equal Date.new(2019, 10, 15), purchase.invoiced_at.to_date

    @inbound.reload
    assert @inbound.matched?
    assert_equal purchase.id, @inbound.purchase_id
  end

  def test_is_idempotent
    first = Qonto::PurchaseFromInboundInvoice.call(@inbound)
    assert_no_difference 'PurchaseInvoice.count' do
      again = Qonto::PurchaseFromInboundInvoice.call(@inbound.reload)
      assert_equal first.id, again.id
    end
  end

  def test_materializes_lines_when_default_variant_configured
    variant = ProductNatureVariant.find(8) # used by purchase_items fixtures → yields valid items
    Preference.set!(:qonto_default_purchase_variant_id, variant.id, :integer)
    @inbound.update!(lines: [
      { 'label' => 'Service A', 'quantity' => 2, 'unit_pretax_amount' => 35.0, 'vat_rate' => 20.0 },
      { 'label' => 'Service B', 'quantity' => 1, 'unit_pretax_amount' => 10.0, 'vat_rate' => 20.0 }
    ])

    purchase = Qonto::PurchaseFromInboundInvoice.call(@inbound)

    assert_equal 2, purchase.items.count
    assert purchase.reload.pretax_amount.positive?, 'totals recomputed from items'
    item = purchase.items.reorder(:id).first
    assert_equal variant.id, item.variant_id
    assert_equal 'Service A', item.annotation
    assert_equal 20.0, item.tax.amount.to_f
  end

  def test_no_items_without_default_variant_preference
    @inbound.update!(lines: [{ 'unit_pretax_amount' => 35.0, 'vat_rate' => 20.0 }])
    purchase = Qonto::PurchaseFromInboundInvoice.call(@inbound)
    assert_equal 0, purchase.items.count, 'line materialization is opt-in via the preference'
  end

  def test_skips_line_without_matching_tax
    variant = ProductNatureVariant.find(8)
    Preference.set!(:qonto_default_purchase_variant_id, variant.id, :integer)
    @inbound.update!(lines: [{ 'unit_pretax_amount' => 5.0, 'vat_rate' => 99.9 }]) # no tax at 99.9%
    purchase = Qonto::PurchaseFromInboundInvoice.call(@inbound)
    assert_equal 0, purchase.items.count
  end

  def test_raises_without_identified_supplier
    orphan = Qonto::InboundInvoice.create!(remote_id: 'p-2')
    error = assert_raises(Qonto::PurchaseFromInboundInvoice::Error) do
      Qonto::PurchaseFromInboundInvoice.call(orphan)
    end
    assert_match(/supplier/, error.message)
    assert orphan.reload.to_review?, 'status unchanged on failure'
  end
end
