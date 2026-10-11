# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# The same invoice can already be a purchase (typed, imported…) when it arrives
# through Qonto: creating it again would count it twice.
class Qonto::PurchaseDuplicatesTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008)
    @other_supplier = entities(:entities_009)
  end

  def test_same_supplier_and_same_number_is_a_duplicate_whatever_the_amount
    purchase = create_purchase('FA-100', amount: 999)

    match = Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120))

    assert_equal purchase, match.purchase
    assert_equal :same_supplier, match.certainty
  end

  def test_the_number_is_compared_whatever_its_punctuation
    purchase = create_purchase('FA 2026/001')

    assert_equal purchase, Qonto::PurchaseDuplicates.for(inbound('fa-2026-001')).purchase
  end

  def test_a_purchase_without_external_reference_is_compared_on_its_internal_number
    purchase = create_purchase(nil)

    assert_equal purchase, Qonto::PurchaseDuplicates.for(inbound(purchase.number)).purchase
  end

  def test_another_supplier_with_the_same_number_and_another_amount_is_not_a_duplicate
    create_purchase('FA-100', supplier: @other_supplier, amount: 500)

    assert_nil Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120))
  end

  def test_the_same_number_and_total_under_another_entity_is_a_probable_duplicate
    # The same company often exists twice as an entity.
    purchase = create_purchase('FA-100', supplier: @other_supplier, amount: 120)

    match = Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120))

    assert_equal purchase, match.purchase
    assert_equal :same_amount, match.certainty
  end

  def test_an_unidentified_supplier_still_matches_on_number_and_total
    purchase = create_purchase('FA-100', amount: 120)

    match = Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120, entity: nil))

    assert_equal purchase, match.purchase
    assert_equal :same_amount, match.certainty
  end

  def test_the_total_is_compared_to_the_cent
    create_purchase('FA-100', supplier: @other_supplier, amount: 120.00)

    assert Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120.005, entity: nil))
    assert_nil Qonto::PurchaseDuplicates.for(inbound('FA-100', amount: 120.50, entity: nil))
  end

  def test_a_document_without_number_never_matches
    create_purchase(nil)

    assert_nil Qonto::PurchaseDuplicates.for(inbound(nil))
    assert_nil Qonto::PurchaseDuplicates.for(inbound('  '))
  end

  def test_a_document_already_linked_to_its_purchase_is_not_its_own_duplicate
    purchase = create_purchase('FA-100')
    linked = inbound('FA-100', purchase: purchase)

    assert_nil Qonto::PurchaseDuplicates.for(linked)
  end

  def test_for_all_answers_a_whole_page_by_inbound_id
    first = create_purchase('A-1')
    second = create_purchase('B-2')
    docs = [inbound('A-1'), inbound('B-2'), inbound('C-3')]

    found = Qonto::PurchaseDuplicates.for_all(docs)

    assert_equal [docs[0].id, docs[1].id].sort, found.keys.sort
    assert_equal first, found[docs[0].id].purchase
    assert_equal second, found[docs[1].id].purchase
    assert_equal({}, Qonto::PurchaseDuplicates.for_all([]))
  end

  private

    def create_purchase(reference, supplier: @supplier, amount: nil)
      purchase = PurchaseInvoice.create!(nature: PurchaseNature.by_default || PurchaseNature.first, supplier: supplier,
                                         reference_number: reference, invoiced_at: Date.new(2019, 10, 15).to_time, currency: 'EUR')
      purchase.update_columns(amount: amount) if amount
      purchase
    end

    def inbound(number, amount: 120, entity: @supplier, purchase: nil)
      Qonto::InboundInvoice.create!(remote_id: SecureRandom.hex(6), invoice_number: number, amount: amount,
                                    entity: entity, purchase: purchase, currency: 'EUR')
    end
end
