# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_lettering'

module Qonto
  class ExpensesControllerTest < Ekylibre::Testing::ApplicationControllerTestCase::WithFixtures
    include QontoLettering
    setup_sign_in

    setup do
      @cash = cashes(:cashes_001)
      @statement = @cash.bank_statements.create!(number: 'exp-2019-10', started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31))
      @card = create_item('tx-card', 'O HANGAR', 27.7, nature: 'card')
      @fee = create_item('tx-fee', 'Frais Qonto', 9.0, nature: 'qonto_fee')
      @credit = create_item('tx-in', 'Virement recu', 0, nature: 'transfer', credit: 50.0)
      @lettered = create_item('tx-done', 'Deja fait', 12.0, nature: 'card')
      @lettered.update_columns(letter: 'AB')
    end

    test '#index lists the unjustified spending lines and nothing else' do
      get :index, params: { current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }

      assert_response :success
      assert_equal [@card.id], assigns(:items).map(&:id)
      assert_equal 1, assigns(:counts)['to_justify']
    end

    test '#index can show the bank fees too' do
      get :index, params: { all_types: 1, current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }

      assert_equal [@card.id, @fee.id].sort, assigns(:items).map(&:id).sort
    end

    test '#index suggests the purchase of a document Qonto matched to the line' do
      supplier = entities(:entities_008)
      Qonto::InboundInvoice.create!(remote_id: 'r-1', kind: 'invoice', entity: supplier, invoice_number: 'FA-1', amount: 27.7, currency: 'EUR',
                                    payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'tx-card' }] })

      get :index, params: { current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }

      assert_response :success
      assert_equal :inbound_invoice, assigns(:suggestions)[@card.id].source
      assert_select 'a.btn-primary[href^=?]', new_backend_quick_purchase_path
      assert_select 'a[href*=?]', 'bank_statement_item_ids'
    end

    test '#index shows the supplier recognised from an earlier payment and the purchase it follows' do
      @lettering_statement = @statement
      mode = outgoing_payment_modes(:outgoing_payment_modes_001)
      supplier = entities(:entities_008)
      lettered_purchase(cash: mode.cash, mode: mode, supplier: supplier, label: 'O HANGAR')
      model = @last_purchase

      get :index, params: { current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }

      assert_response :success
      assert_equal :supplier_model, assigns(:suggestions)[@card.id].source
      assert_select 'td', text: /#{Regexp.escape(supplier.full_name)}/
      assert_select 'td', text: /#{Regexp.escape(model.number)}/
      assert_select 'a.btn-primary[href^=?]', new_backend_quick_purchase_path
    end

    test '#ignore sets the line aside without touching its figures' do
      before = @card.reload.attributes.except('provider', 'updated_at')

      post :ignore, params: { id: @card.id }

      assert_redirected_to qonto_expenses_path
      assert_equal 'ignored', provider_data(@card)['expense_review']
      assert_equal before, @card.reload.attributes.except('provider', 'updated_at')

      get :index, params: { current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }
      assert_empty assigns(:items)
      get :index, params: { status: 'ignored', current_financial_year: FinancialYear.on(Date.new(2019, 10, 15)).id }
      assert_equal [@card.id], assigns(:items).map(&:id)
    end

    test '#fetch_document warns when the line has no known attachment' do
      post :fetch_document, params: { id: @card.id }

      assert_redirected_to qonto_expenses_path
    end

    test '#fetch_document downloads the files of the line, without writing anything to Qonto' do
      @card.update_column(:provider, @card.provider.to_h.merge('data' => { 'attachment_ids' => ['att-1'] }))
      called = nil
      Qonto::DocumentsImportService.stub(:call, ->(**args) { called = args; 1 }) do
        post :fetch_document, params: { id: @card.id }
      end

      assert_redirected_to qonto_expenses_path
      assert_equal [@card.id], called[:items].map(&:id)
    end

    test '#restore puts an ignored line back' do
      post :ignore, params: { id: @card.id }
      post :restore, params: { id: @card.id }

      assert_not provider_data(@card).key?('expense_review')
      assert_equal 'tx-card', @card.reload.provider[:id] || @card.provider['id'], 'the rest of the provider is kept'
    end

    test '#finalize on a line that is not lettered warns and goes back to the list' do
      get :finalize, params: { id: @card.id }

      assert_redirected_to qonto_expenses_path
      assert_equal 1, flash.keep(:notifications)['warning'].count
    end

    private

      def provider_data(item)
        provider = item.reload.provider.to_h
        (provider[:data] || provider['data']).to_h.stringify_keys
      end

      def create_item(provider_id, name, debit, nature:, credit: 0)
        @statement.items.create!(
          name: name, transfered_on: Date.new(2019, 10, 15), debit: debit, credit: credit, transaction_nature: nature,
          provider: { vendor: 'qonto', name: 'transaction', id: provider_id, data: {} }
        )
      end
  end
end
