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

      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
      assert_equal supplier.id, invoice.reload.entity_id
      assert_equal 1, flash.keep(:notifications)['success'].count
    end

    test '#attach_supplier without a selection notifies an error and changes nothing' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-2')

      post :attach_supplier, params: { id: invoice.id, qonto_inbound_invoice: { entity_id: '' } }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
      assert_nil invoice.reload.entity_id
      assert_equal 1, flash.keep(:notifications)['error'].count
    end

    test '#ignore moves the invoice to ignored' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-3')

      post :ignore, params: { id: invoice.id }

      assert invoice.reload.ignored?
      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
    end

    test '#create_purchase warns when the supplier is not identified' do
      invoice = Qonto::InboundInvoice.create!(remote_id: 'ctrl-4') # no entity

      post :create_purchase, params: { id: invoice.id }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
      assert_equal 1, flash.keep(:notifications)['warning'].count
      assert invoice.reload.to_review?
    end

    test 'actions send the user back to the tab of the document kind' do
      expense = Qonto::InboundInvoice.create!(remote_id: 'ctrl-5', kind: 'expense')

      post :ignore, params: { id: expense.id }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'expense', status: 'to_review')
    end

    test '#create_purchase refuses a card receipt: it is not a purchase' do
      receipt = Qonto::InboundInvoice.create!(remote_id: 'ctrl-6', kind: 'receipt', entity: entities(:entities_008))

      assert_no_difference 'PurchaseInvoice.count' do
        post :create_purchase, params: { id: receipt.id }
      end

      assert_redirected_to qonto_inbound_invoices_path(kind: 'receipt', status: 'to_review')
      assert_equal 1, flash.keep(:notifications)['error'].count
      assert receipt.reload.to_review?
    end

    test '#attach_to_statement attaches a receipt to its bank line' do
      cash = cashes(:cashes_001)
      statement = cash.bank_statements.create!(number: 'ctrl-st', started_on: Date.new(2019, 10, 1), stopped_on: Date.new(2019, 10, 31))
      item = statement.items.create!(
        name: 'item', transfered_on: Date.new(2019, 10, 15), credit: 10.0,
        provider: { vendor: 'qonto', name: 'transaction', id: 'ctrl-tx', data: {} }
      )
      document = Document.create!(key: 'ctrl-doc', name: 'r.pdf', processable_attachment: false)
      receipt = Qonto::InboundInvoice.create!(
        remote_id: 'ctrl-7', kind: 'receipt', document: document,
        payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'ctrl-tx' }] }
      )

      post :attach_to_statement, params: { id: receipt.id }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'receipt', status: 'to_review')
      assert_equal [document.id], item.attachments.map(&:document_id)
      assert receipt.reload.matched?
      assert_equal 1, flash.keep(:notifications)['success'].count
    end

    test '#attach_to_statement explains when the bank line is not there yet' do
      receipt = Qonto::InboundInvoice.create!(
        remote_id: 'ctrl-8', kind: 'receipt',
        document: Document.create!(key: 'ctrl-doc-2', name: 'r.pdf', processable_attachment: false),
        payload: { matched_transactions: [{ subject_type: 'transaction', transaction_id: 'unknown-tx' }] }
      )

      post :attach_to_statement, params: { id: receipt.id }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'receipt', status: 'to_review')
      assert_equal 1, flash.keep(:notifications)['error'].count
      assert receipt.reload.to_review?
    end

    # The backend layout needs compiled webpacker packs, which the test
    # environment does not have: render the page without it.
    test '#index renders the tabs by kind, the lines of an e-invoice and the action of each kind' do
      supplier = entities(:entities_008)
      year = FinancialYear.on(Date.new(2019, 10, 15))
      invoice = Qonto::InboundInvoice.create!(
        remote_id: 'view-1', kind: 'invoice', entity: supplier, issued_on: Date.new(2019, 10, 15), invoice_number: 'FA-V1', currency: 'EUR', amount: 144, pretax_amount: 120,
        lines: [{ 'label' => 'Semences de blé', 'quantity' => '10.0', 'unit_code' => 'KGM', 'unit_pretax_amount' => '10.0',
                  'vat_rate' => '20.0', 'total_pretax_amount' => '100.0' }]
      )
      Qonto::InboundInvoice.create!(remote_id: 'view-2', kind: 'expense', entity: supplier, issued_on: Date.new(2019, 10, 15), invoice_number: 'NDF-1')
      Qonto::InboundInvoice.create!(remote_id: 'view-3', kind: 'receipt', issued_on: Date.new(2019, 10, 15), invoice_number: 'RC-1')

      without_layout do
        get :index, params: { kind: 'invoice', current_financial_year: year.id }
        assert_response :success
        assert_select 'ul.nav-tabs li', 4
        assert_select 'ul.nav-tabs li.active', 1
        assert_select 'td', text: /FA-V1/
        assert_select "details#qonto-lines-#{invoice.id}", 1
        assert_select "details#qonto-lines-#{invoice.id} td", text: /Semences de blé/
        assert_select "a[href=?]", create_purchase_qonto_inbound_invoice_path(invoice)

        get :index, params: { kind: 'expense', current_financial_year: year.id }
        assert_select 'td', text: /NDF-1/
        assert_select 'td', text: /FA-V1/, count: 0

        get :index, params: { kind: 'receipt', current_financial_year: year.id }
        assert_select 'td', text: /RC-1/
        assert_select 'a[href*=?]', 'attach_to_statement'
        assert_select 'a[href*=?]', 'create_purchase', count: 0
      end
    end

    test '#index falls back to invoices and to review for unknown tabs' do
      without_layout do
        get :index, params: { kind: 'selfie', status: 'bogus' }
        assert_response :success
      end
    end

    test '#index only lists the documents of the chosen financial year and says what is elsewhere' do
      year = FinancialYear.on(Date.new(2019, 10, 15))
      Qonto::InboundInvoice.create!(remote_id: 'fy-in', invoice_number: 'IN-2019', issued_on: Date.new(2019, 10, 15))
      Qonto::InboundInvoice.create!(remote_id: 'fy-out', invoice_number: 'OUT-2015', issued_on: Date.new(2015, 3, 1))
      Qonto::InboundInvoice.create!(remote_id: 'fy-out-2', invoice_number: 'OUT-2016', issued_on: Date.new(2016, 3, 1))

      without_layout do
        get :index, params: { current_financial_year: year.id }

        assert_response :success
        assert_select 'td', text: /IN-2019/
        assert_select 'td', text: /OUT-2015/, count: 0
        # The badge of the tab counts the exercise only; the note counts the rest.
        assert_select 'ul.nav-tabs li.active .badge', text: '1'
        assert_select 'p.text-muted', text: /2/
      end
    end

    test '#index keeps the chosen financial year for the next pages' do
      year = FinancialYear.on(Date.new(2019, 10, 15))

      without_layout { get :index, params: { current_financial_year: year.id } }

      assert_equal year, @controller.send(:current_financial_year)
    end

    # -- one invoice, one purchase ---------------------------------------------

    test '#create_purchase refuses an invoice that is already a purchase and says which' do
      supplier = entities(:entities_008)
      existing = create_purchase('FA-DUP', supplier)
      invoice = Qonto::InboundInvoice.create!(remote_id: 'dup-1', entity: supplier, invoice_number: 'FA-DUP', issued_on: Date.new(2019, 10, 15))

      assert_no_difference 'PurchaseInvoice.count' do
        post :create_purchase, params: { id: invoice.id }
      end

      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
      warning = flash.keep(:notifications)['warning']
      assert_equal 1, warning.count
      assert_includes warning.first.to_s, existing.number
      assert invoice.reload.to_review?
    end

    test '#create_purchase creates it anyway when the accountant insists' do
      supplier = entities(:entities_008)
      create_purchase('FA-DUP', supplier)
      invoice = Qonto::InboundInvoice.create!(remote_id: 'dup-2', entity: supplier, invoice_number: 'FA-DUP', issued_on: Date.new(2019, 10, 15))

      assert_difference 'PurchaseInvoice.count', 1 do
        post :create_purchase, params: { id: invoice.id, force: 1 }
      end

      assert invoice.reload.matched?
      assert_redirected_to edit_backend_purchase_invoice_path(invoice.purchase)
    end

    test '#create_purchase refuses an invoice your own company issued' do
      Entity.of_company.update_columns(siret_number: '12345678200019')
      invoice = Qonto::InboundInvoice.create!(remote_id: 'own-c', entity: entities(:entities_008), invoice_number: 'F-OWN',
                                              supplier_siret: '12345678200019', issued_on: Date.new(2019, 10, 15))

      assert_no_difference 'PurchaseInvoice.count' do
        post :create_purchase, params: { id: invoice.id, force: 1 }
      end

      assert_equal 1, flash.keep(:notifications)['error'].count
      assert invoice.reload.to_review?
    end

    test '#link_purchase links the document to the existing purchase instead of creating one' do
      supplier = entities(:entities_008)
      existing = create_purchase('FA-LINK', supplier)
      invoice = Qonto::InboundInvoice.create!(remote_id: 'link-1', entity: supplier, invoice_number: 'FA-LINK')

      assert_no_difference 'PurchaseInvoice.count' do
        post :link_purchase, params: { id: invoice.id, purchase_id: existing.id }
      end

      assert_redirected_to qonto_inbound_invoices_path(kind: 'invoice', status: 'to_review')
      assert invoice.reload.matched?
      assert_equal existing.id, invoice.purchase_id
      assert_equal 1, flash.keep(:notifications)['success'].count
    end

    test '#link_purchase explains why a receipt cannot be linked to a purchase' do
      existing = create_purchase('FA-LINK-2', entities(:entities_008))
      receipt = Qonto::InboundInvoice.create!(remote_id: 'link-2', kind: 'receipt')

      post :link_purchase, params: { id: receipt.id, purchase_id: existing.id }

      assert_redirected_to qonto_inbound_invoices_path(kind: 'receipt', status: 'to_review')
      assert_equal 1, flash.keep(:notifications)['error'].count
      assert receipt.reload.to_review?
    end

    test '#index warns on a document already entered, issued by you, or received twice and offers the right action' do
      supplier = entities(:entities_008)
      year = FinancialYear.on(Date.new(2019, 10, 15))
      Entity.of_company.update_columns(siret_number: '12345678200019')
      existing = create_purchase('ALREADY-1', supplier)
      day = Date.new(2019, 10, 15)
      already = Qonto::InboundInvoice.create!(remote_id: 'v-1', entity: supplier, invoice_number: 'ALREADY-1', issued_on: day)
      own = Qonto::InboundInvoice.create!(remote_id: 'v-2', entity: supplier, invoice_number: 'F-MINE', issued_on: day, supplier_siret: '12345678200019')
      fresh = Qonto::InboundInvoice.create!(remote_id: 'v-3', entity: supplier, invoice_number: 'FRESH-1', issued_on: day)
      Qonto::InboundInvoice.create!(remote_id: 'v-4', supplier_name: 'Twice SAS', invoice_number: 'TW-1', issued_on: day, created_at: 3.days.ago)
      twin = Qonto::InboundInvoice.create!(remote_id: 'v-5', supplier_name: 'Twice SAS', invoice_number: 'TW-1', issued_on: day)

      without_layout do
        get :index, params: { kind: 'invoice', current_financial_year: year.id }
        assert_response :success

        # already a purchase: link is the main action, creating anyway needs confirmation
        assert_select 'span.label-danger', text: /./, count: 1
        assert_select "a[href=?]", backend_purchase_path(existing), text: existing.number
        assert_select 'a[href*=?]', link_purchase_qonto_inbound_invoice_path(already), count: 1
        assert_select 'a[href*=?][data-confirm]', 'force=1', count: 1

        # your own invoice: labelled, nothing to create
        assert_select 'span.label-info', count: 1
        assert_select 'a[href=?]', create_purchase_qonto_inbound_invoice_path(own), count: 0

        # a normal one keeps the plain button
        assert_select 'a[href=?]', create_purchase_qonto_inbound_invoice_path(fresh), count: 1

        # received twice: the later one is flagged
        assert_select 'span.label-warning', text: /./, minimum: 1
        assert twin
      end
    end

    private

      def create_purchase(reference, supplier)
        PurchaseInvoice.create!(nature: PurchaseNature.by_default || PurchaseNature.first, supplier: supplier,
                                reference_number: reference, invoiced_at: Date.new(2019, 10, 15).to_time, currency: 'EUR')
      end

      def without_layout(&block)
        @controller.stub(:_layout, ->(*) { false }, &block)
      end
  end
end
