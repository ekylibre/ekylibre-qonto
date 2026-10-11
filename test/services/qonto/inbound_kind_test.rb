# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

class Qonto::InboundKindTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_maps_qonto_attachment_categories
    assert_equal 'invoice', Qonto::InboundKind.for(attachment_category: 'INVOICE')
    assert_equal 'expense', Qonto::InboundKind.for(attachment_category: 'EXPENSE_RECEIPT')
    assert_equal 'receipt', Qonto::InboundKind.for(attachment_category: 'CARD_RECEIPT')
    assert_equal 'other', Qonto::InboundKind.for(attachment_category: 'OTHER_FINANCIAL_DOCUMENT')
    assert_equal 'other', Qonto::InboundKind.for(attachment_category: 'UNKNOWN')
  end

  def test_anything_unrecognised_is_other_never_an_invoice
    assert_equal 'other', Qonto::InboundKind.for({})
    assert_equal 'other', Qonto::InboundKind.for(attachment_category: nil)
    assert_equal 'other', Qonto::InboundKind.for(attachment_category: 'SOMETHING_NEW')
  end

  def test_is_case_insensitive
    assert_equal 'expense', Qonto::InboundKind.for(attachment_category: 'expense_receipt')
  end

  def test_a_document_delivered_by_the_network_is_always_an_invoice
    assert_equal 'invoice', Qonto::InboundKind.for(source_type: 'e_invoicing', attachment_category: 'UNKNOWN')
    assert_equal 'invoice', Qonto::InboundKind.for(source_type: 'e_invoicing')
  end

  def test_kinds_split_between_purchases_and_statement_documents
    assert_equal Qonto::InboundKind::KINDS.sort,
                 (Qonto::InboundKind::PURCHASE_KINDS + Qonto::InboundKind::STATEMENT_KINDS).sort
  end
end
