# frozen_string_literal: true

require 'test_helper'

class Qonto::InboundInvoiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_defaults_and_status_predicates
    invoice = Qonto::InboundInvoice.create!(remote_id: 'r-1')
    assert invoice.to_review?
    refute invoice.matched?
    refute invoice.supplier_known?
  end

  def test_remote_id_uniqueness
    Qonto::InboundInvoice.create!(remote_id: 'r-dup')
    dup = Qonto::InboundInvoice.new(remote_id: 'r-dup')
    refute dup.valid?
    assert dup.errors[:remote_id].present?
  end

  def test_status_scopes
    a = Qonto::InboundInvoice.create!(remote_id: 'r-a', status: 'to_review')
    b = Qonto::InboundInvoice.create!(remote_id: 'r-b', status: 'ignored')
    assert_includes Qonto::InboundInvoice.to_review, a
    assert_includes Qonto::InboundInvoice.ignored, b
    refute_includes Qonto::InboundInvoice.to_review, b
  end

  def test_supplier_known_when_entity_set
    entity = entities(:entities_008)
    invoice = Qonto::InboundInvoice.create!(remote_id: 'r-e', entity: entity)
    assert invoice.supplier_known?
  end
end
