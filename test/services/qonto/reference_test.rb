# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::ReferenceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_the_same_invoice_written_three_ways_is_one_reference
    refs = ['FA 2026/001', 'fa-2026-001', 'FA2026001', ' fa.2026.001 '].map { |v| Qonto::Reference.normalize(v) }

    assert_equal ['FA2026001'], refs.uniq
  end

  def test_blank_stays_blank
    assert_equal '', Qonto::Reference.normalize(nil)
    assert_equal '', Qonto::Reference.normalize(' / - ')
  end

  def test_the_sql_form_agrees_with_the_ruby_form
    purchase = create_purchase('fa-2026/001')

    found = PurchaseInvoice.where("#{Qonto::Reference.sql("COALESCE(NULLIF(purchases.reference_number, ''), purchases.number)")} = ?",
                                  Qonto::Reference.normalize('FA 2026 001'))
    assert_includes found, purchase
  end

  private

    def create_purchase(reference)
      PurchaseInvoice.create!(nature: PurchaseNature.by_default || PurchaseNature.first, supplier: entities(:entities_008),
                              reference_number: reference, invoiced_at: Date.new(2019, 10, 15).to_time, currency: 'EUR')
    end
end
