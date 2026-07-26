# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

module Qonto
  class InboundInvoicesControllerTest < Ekylibre::Testing::ApplicationControllerTestCase::WithFixtures
    setup_sign_in

    test '#attach_supplier links an existing entity and redirects' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-1')
      supplier = entities(:entities_008)

      post :attach_supplier, params: { id: invoice.id, qonto_inbound_invoice: { entity_id: supplier.id } }

      assert_redirected_to qonto_inbound_invoices_path(status: 'to_review')
      assert_equal supplier.id, invoice.reload.entity_id
      assert_equal 1, flash.keep(:notifications)['success'].count
    end

    test '#attach_supplier without a selection notifies an error and changes nothing' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-2')

      post :attach_supplier, params: { id: invoice.id, qonto_inbound_invoice: { entity_id: '' } }

      assert_redirected_to qonto_inbound_invoices_path(status: 'to_review')
      assert_nil invoice.reload.entity_id
      assert_equal 1, flash.keep(:notifications)['error'].count
    end

    test '#ignore moves the invoice to ignored' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-3')

      post :ignore, params: { id: invoice.id }

      assert invoice.reload.ignored?
      assert_redirected_to qonto_inbound_invoices_path(status: 'to_review')
    end

    test '#create_purchase warns when the supplier is not identified' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-4') # no entity

      post :create_purchase, params: { id: invoice.id }

      assert_redirected_to qonto_inbound_invoices_path(status: 'to_review')
      assert_equal 1, flash.keep(:notifications)['warning'].count
      assert invoice.reload.to_review?
    end
  end
end
