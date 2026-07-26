# frozen_string_literal: true

module Qonto
  # Emission: trigger sending a Sale by e-invoice, and the emission tracking
  # screen (S4) whose single question is "what is stuck?".
  class OutboundInvoicesController < Backend::BaseController
    def index
      @counts = OutboundInvoice.group(:status).count
      @stalled = OutboundInvoice.stalled.count
      # failed first, then in-progress oldest, then the rest.
      @outbound_invoices = OutboundInvoice.includes(:sale).order(
        Arel.sql("CASE status WHEN 'failed' THEN 0 WHEN 'submitted' THEN 1 WHEN 'issued' THEN 2 ELSE 3 END"),
        submitted_at: :asc
      )
    end

    # Server-rendered fragment for progressive polling (S2). Returns the current
    # DB state — the lifecycle advances via the webhook / hourly poll, never a
    # synchronous HTTP call here.
    def status
      outbound = OutboundInvoice.find(params[:id])
      render json: {
        html: render_to_string(partial: 'qonto/einvoicing_timeline',
                               locals: { outbound: outbound }, formats: [:html]),
        in_progress: outbound.in_progress?
      }
    end

    def create
      sale = Sale.find(params[:sale_id])

      unless sale.invoice?
        notify_warning(:only_invoices_can_be_sent_by_einvoice.tl)
        return redirect_to backend_sale_path(sale)
      end

      mentions = Qonto::MandatoryMentions.new(sale)
      unless mentions.complete?
        missing = mentions.missing.map { |m| "einvoice_mention_#{m}".to_sym.tl }.to_sentence
        notify_error(:missing_mandatory_mentions.tl(mentions: missing))
        return redirect_to backend_sale_path(sale)
      end

      Qonto::SendEInvoiceJob.perform_later(sale_id: sale.id)
      # A 204 does not mean "sent": never claim success, only "in progress".
      notify_success(:einvoice_transmission_in_progress.tl)
      redirect_to backend_sale_path(sale)
    end
  end
end
