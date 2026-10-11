# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::LinkToExistingPurchaseTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008)
    @purchase = PurchaseInvoice.create!(nature: PurchaseNature.by_default || PurchaseNature.first, supplier: @supplier,
                                        reference_number: 'FA-100', invoiced_at: Date.new(2019, 10, 15).to_time, currency: 'EUR')
    @document = Document.create!(nature: 'purchases_invoice', key: 'k-link', name: 'fa.pdf', processable_attachment: false)
    @inbound = Qonto::InboundInvoice.create!(remote_id: 'l-1', invoice_number: 'FA-100', entity: @supplier, document: @document)
  end

  def test_links_the_two_and_closes_the_inbox_entry_without_creating_a_purchase
    assert_no_difference 'PurchaseInvoice.count' do
      assert_equal @purchase, Qonto::LinkToExistingPurchase.call(@inbound, @purchase)
    end

    @inbound.reload
    assert @inbound.matched?
    assert_equal @purchase.id, @inbound.purchase_id
  end

  def test_the_file_joins_the_existing_purchase
    assert_difference '@purchase.attachments.count', 1 do
      Qonto::LinkToExistingPurchase.call(@inbound, @purchase)
    end
    assert_equal [@document.id], @purchase.attachments.map(&:document_id)
  end

  def test_linking_twice_attaches_the_file_once
    Qonto::LinkToExistingPurchase.call(@inbound, @purchase)

    assert_no_difference '@purchase.attachments.count' do
      Qonto::LinkToExistingPurchase.call(@inbound.reload, @purchase)
    end
  end

  def test_the_supplier_of_the_purchase_is_adopted_when_the_inbox_did_not_know_it
    @inbound.update!(entity: nil)

    Qonto::LinkToExistingPurchase.call(@inbound, @purchase)
    assert_equal @supplier.id, @inbound.reload.entity_id
  end

  def test_works_without_a_file
    @inbound.update!(document: nil)

    Qonto::LinkToExistingPurchase.call(@inbound, @purchase)
    assert @inbound.reload.matched?
  end

  def test_refuses_a_document_already_linked_to_another_purchase
    other = PurchaseInvoice.create!(nature: @purchase.nature, supplier: @supplier, reference_number: 'FA-200',
                                    invoiced_at: Date.new(2019, 10, 16).to_time, currency: 'EUR')
    @inbound.update!(purchase: other, status: 'matched')

    assert_raises(Qonto::LinkToExistingPurchase::Error) { Qonto::LinkToExistingPurchase.call(@inbound, @purchase) }
    assert_equal other.id, @inbound.reload.purchase_id
  end

  def test_refuses_what_is_not_a_purchase
    @inbound.update!(kind: 'receipt')

    assert_raises(Qonto::LinkToExistingPurchase::Error) { Qonto::LinkToExistingPurchase.call(@inbound, @purchase) }
    assert @inbound.reload.to_review?
  end

  def test_refuses_something_that_is_not_a_purchase_invoice
    assert_raises(Qonto::LinkToExistingPurchase::Error) { Qonto::LinkToExistingPurchase.call(@inbound, @supplier) }
  end
end
