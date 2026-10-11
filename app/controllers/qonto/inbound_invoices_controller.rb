# frozen_string_literal: true

module Qonto
  # Reception inbox for what suppliers and cards send through Qonto (S3). One
  # tab per kind, because Ekylibre does not treat them as the same object, then
  # one per status. The primary per-row action depends on the kind: supplier
  # invoices and expense reports become a Purchase (the ressaisie that
  # disappears), card receipts and other documents justify a bank line.
  class InboundInvoicesController < Backend::BaseController
    def index
      @kind = InboundInvoice::KINDS.include?(params[:kind]) ? params[:kind] : 'invoice'
      @status = InboundInvoice::STATUSES.include?(params[:status]) ? params[:status] : 'to_review'
      # Same exercise selector as the accountancy dashboard: Backend::BaseController
      # keeps the chosen one on the user, the view displays the selector.
      scope = InboundInvoice.in_financial_year(current_financial_year)
      # Status badges describe the current kind; kind badges count what is left to do.
      @counts = scope.of_kind(@kind).group(:status).count
      @to_review_counts = scope.to_review.group(:kind).count
      # So that nothing looks lost when the chosen exercise is not the one the documents are in.
      @to_review_elsewhere = InboundInvoice.to_review.count - @to_review_counts.values.sum
      @inbound_invoices = scope.of_kind(@kind).where(status: @status).recent.to_a
      # Warnings shown on the rows, each computed once for the whole page.
      to_handle = @inbound_invoices.select { |i| i.to_review? && i.purchasable? }
      @existing_purchases = Qonto::PurchaseDuplicates.for_all(to_handle)
      @own_company = Qonto::OwnCompany.current
      @inbox_originals = Qonto::InboundDuplicates.originals_for(@inbound_invoices)
      # Only what exists is displayed: preload those, not a nil for the others.
      preloader = ActiveRecord::Associations::Preloader.new
      preloader.preload(@inbound_invoices.select(&:entity_id), :entity)
      preloader.preload(@inbound_invoices.select(&:document_id), :document)
    end

    def ignore
      invoice = InboundInvoice.find(params[:id])
      invoice.update!(status: 'ignored')
      notify_success(:einvoice_ignored.tl)
      redirect_to inbox_path_for(invoice)
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
      redirect_to inbox_path_for(invoice)
    end

    # Turns the received invoice into a draft PurchaseInvoice (supplier,
    # reference, date, PDF pre-filled), links it back, flips the status to
    # matched, and lands the accountant on the purchase edit screen to map the
    # lines. Requires an identified supplier.
    def create_purchase
      invoice = InboundInvoice.find(params[:id])

      unless invoice.supplier_known?
        notify_warning(:identify_supplier_before_creating_purchase.tl)
        return redirect_to inbox_path_for(invoice)
      end

      purchase = Qonto::PurchaseFromInboundInvoice.call(invoice, force: params[:force].present?)
      notify_success(:purchase_created_from_einvoice.tl)
      redirect_to edit_backend_purchase_invoice_path(purchase)
    rescue Qonto::PurchaseFromInboundInvoice::DuplicateError => e
      # Never a silent second purchase: say which one, the accountant links or insists.
      notify_warning(:einvoice_purchase_already_exists.tl(number: e.match.purchase.number))
      redirect_to inbox_path_for(invoice)
    rescue Qonto::PurchaseFromInboundInvoice::Error => e
      notify_error(:could_not_create_purchase.tl(message: e.message))
      redirect_to inbox_path_for(invoice)
    end

    # The invoice is already a purchase: link them rather than create another.
    def link_purchase
      invoice = InboundInvoice.find(params[:id])
      purchase = PurchaseInvoice.find(params[:purchase_id])
      Qonto::LinkToExistingPurchase.call(invoice, purchase)
      notify_success(:einvoice_linked_to_purchase.tl(number: purchase.number))
      redirect_to inbox_path_for(invoice)
    rescue Qonto::LinkToExistingPurchase::Error => e
      notify_error(:could_not_link_purchase.tl(message: e.message))
      redirect_to inbox_path_for(invoice)
    end

    # Card receipts and other documents: attach the file to the bank statement
    # line Qonto matched it with. No purchase is created.
    def attach_to_statement
      invoice = InboundInvoice.find(params[:id])
      Qonto::AttachToBankStatement.call(invoice)
      notify_success(:einvoice_attached_to_statement.tl)
      redirect_to inbox_path_for(invoice)
    rescue Qonto::AttachToBankStatement::Error => e
      notify_error(:could_not_attach_to_statement.tl(message: e.message))
      redirect_to inbox_path_for(invoice)
    end

    private

      # Back to the tab the document came from.
      def inbox_path_for(invoice)
        qonto_inbound_invoices_path(kind: invoice.kind, status: 'to_review')
      end
  end
end
