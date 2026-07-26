# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

module Qonto
  class OutboundInvoicesControllerTest < Ekylibre::Testing::ApplicationControllerTestCase::WithFixtures
    setup_sign_in

    test '#create enqueues the send job when mentions are complete' do
      sale = sales(:sales_001)
      assert sale.invoice?
      complete_mentions!(sale)

      captured = nil
      Qonto::SendEInvoiceJob.stub(:perform_later, ->(**kw) { captured = kw }) do
        post :create, params: { sale_id: sale.id }
      end

      assert_equal({ sale_id: sale.id }, captured)
      assert_redirected_to backend_sale_path(sale)
      assert_equal 1, flash.keep(:notifications)['success'].count
    end

    test '#create is blocked when mandatory mentions are incomplete' do
      sale = sales(:sales_001)
      sale.update_columns(delivery_address_id: nil) # at least one gap

      called = false
      Qonto::SendEInvoiceJob.stub(:perform_later, ->(**) { called = true }) do
        post :create, params: { sale_id: sale.id }
      end

      refute called
      assert_equal 1, flash.keep(:notifications)['error'].count
      assert_redirected_to backend_sale_path(sale)
    end

    test '#status returns the server-rendered timeline and the in_progress flag' do
      outbound = Qonto::OutboundInvoice.create!(sale: sales(:sales_001), remote_id: 'st-1', status: 'submitted')

      get :status, params: { id: outbound.id }

      assert_response :success
      json = JSON.parse(response.body)
      assert json['in_progress']
      assert_includes json['html'], 'einvoicing-timeline'
    end

    test '#create warns for a non-invoice sale and enqueues nothing' do
      sale = sales(:sales_002)
      refute sale.invoice?

      called = false
      Qonto::SendEInvoiceJob.stub(:perform_later, ->(**) { called = true }) do
        post :create, params: { sale_id: sale.id }
      end

      refute called
      assert_equal 1, flash.keep(:notifications)['warning'].count
      assert_redirected_to backend_sale_path(sale)
    end

    private

      def complete_mentions!(sale)
        sale.client.update_columns(siret_number: '12369874500015')
        sale.update_columns(delivery_address_id: EntityAddress.first.id)
        # operation_category is derived from the (goods) lines; the VAT option is
        # the current financial year's tax declaration mode.
        FinancialYear.current.update_columns(tax_declaration_mode: 'debit')
      end
  end
end
