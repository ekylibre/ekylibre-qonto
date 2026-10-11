# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# Supplier invoices and expense reports are both purchases but not the same
# nature; everything else is not a purchase.
class Qonto::PurchaseFromInboundInvoiceKindsTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @supplier = entities(:entities_008)
  end

  def test_an_invoice_uses_the_default_nature
    purchase = Qonto::PurchaseFromInboundInvoice.call(inbound('i-1', kind: 'invoice'))

    assert_equal (PurchaseNature.by_default || PurchaseNature.first).id, purchase.nature_id
  end

  def test_an_expense_report_gets_its_own_nature_on_the_default_journal
    default = PurchaseNature.by_default || PurchaseNature.first

    purchase = nil
    assert_difference 'PurchaseNature.count', 1 do
      purchase = Qonto::PurchaseFromInboundInvoice.call(inbound('x-1', kind: 'expense'))
    end

    assert_equal :expense_report_nature.tl, purchase.nature.name
    assert_equal default.journal_id, purchase.nature.journal_id
    refute purchase.nature.by_default, 'must never become the default nature of the tenant'
    assert purchase.is_a?(PurchaseInvoice)
  end

  def test_the_expense_nature_is_reused
    Qonto::PurchaseFromInboundInvoice.call(inbound('x-2', kind: 'expense'))

    assert_no_difference 'PurchaseNature.count' do
      second = Qonto::PurchaseFromInboundInvoice.call(inbound('x-3', kind: 'expense'))
      assert_equal :expense_report_nature.tl, second.nature.name
    end
  end

  def test_the_expense_nature_is_found_whatever_the_tenant_language
    Qonto::PurchaseFromInboundInvoice.call(inbound('x-4', kind: 'expense'))

    assert_no_difference 'PurchaseNature.count' do
      I18n.with_locale(:fra) { Qonto::PurchaseFromInboundInvoice.call(inbound('x-5', kind: 'expense')) }
    end
  end

  def test_receipts_and_other_documents_are_not_purchases
    %w[receipt other].each do |kind|
      assert_no_difference 'PurchaseInvoice.count' do
        error = assert_raises(Qonto::PurchaseFromInboundInvoice::Error) { Qonto::PurchaseFromInboundInvoice.call(inbound("n-#{kind}", kind: kind)) }
        assert_match(/not a purchase/, error.message)
      end
    end
  end

  def test_credit_notes_are_refused_rather_than_booked_as_invoices
    credit = inbound('c-1', kind: 'invoice', payload: { is_credit_note: true })

    assert_no_difference 'PurchaseInvoice.count' do
      error = assert_raises(Qonto::PurchaseFromInboundInvoice::Error) { Qonto::PurchaseFromInboundInvoice.call(credit) }
      assert_match(/credit notes/, error.message)
    end
  end

  private

    def inbound(remote_id, kind:, payload: {})
      Qonto::InboundInvoice.create!(
        remote_id: remote_id, kind: kind, entity: @supplier, invoice_number: "N-#{remote_id}", currency: 'EUR',
        issued_on: Date.new(2019, 10, 15), amount: 100, pretax_amount: 100, payload: payload
      )
    end
end
