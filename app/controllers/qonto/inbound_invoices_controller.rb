# frozen_string_literal: true

module Qonto
  # Reception inbox for supplier e-invoices (S3). Tabs by status; the primary
  # per-row action turns a received invoice into a Purchase (the ressaisie that
  # disappears).
  class InboundInvoicesController < Backend::BaseController
    def index
      @status = InboundInvoice::STATUSES.include?(params[:status]) ? params[:status] : 'to_review'
      @counts = InboundInvoice.group(:status).count
      @inbound_invoices = InboundInvoice.where(status: @status).recent
    end

    def ignore
      invoice = InboundInvoice.find(params[:id])
      invoice.update!(status: 'ignored')
      notify_success(:einvoice_ignored.tl)
      redirect_to qonto_inbound_invoices_path(status: 'to_review')
    end

    # Attach an existing Entity as the supplier (native unroll autocomplete),
    # for invoices whose SIRET could not be pre-reconciled. The invoice stays
    # "to_review" — now with a known supplier, "Create the purchase" unlocks.
    def attach_supplier
      invoice = InboundInvoice.find(params[:id])
      entity_id = params.dig(:qonto_inbound_invoice, :entity_id).presence || params[:entity_id].presence
      entity = Entity.find_by(id: entity_id)

      if entity
        invoice.update!(entity: entity)
        notify_success(:supplier_attached.tl)
      else
        notify_error(:select_a_supplier.tl)
      end
      redirect_to qonto_inbound_invoices_path(status: 'to_review')
    end

    # Turns the received invoice into a draft PurchaseInvoice (supplier,
    # reference, date, PDF pre-filled), links it back, flips the status to
    # matched, and lands the accountant on the purchase edit screen to map the
    # lines. Requires an identified supplier.
    def create_purchase
      invoice = InboundInvoice.find(params[:id])

      unless invoice.supplier_known?
        notify_warning(:identify_supplier_before_creating_purchase.tl)
        return redirect_to qonto_inbound_invoices_path(status: 'to_review')
      end

      purchase = Qonto::PurchaseFromInboundInvoice.call(invoice)
      notify_success(:purchase_created_from_einvoice.tl)
      redirect_to edit_backend_purchase_invoice_path(purchase)
    rescue Qonto::PurchaseFromInboundInvoice::Error => e
      notify_error(:could_not_create_purchase.tl(message: e.message))
      redirect_to qonto_inbound_invoices_path(status: 'to_review')
    end
  end
end
