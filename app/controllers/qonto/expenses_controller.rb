# frozen_string_literal: true

module Qonto
  # Bank lines of the Qonto account that still have no purchase behind them.
  # For each, what the suggester found (a supplier document Qonto matched, a
  # purchase already entered) and a button that opens the usual "new purchase"
  # form of the bank reconciliation, filled in. Nothing is created here: the
  # accountant validates the form, which creates the purchase, the payment and
  # the lettering; coming back through #finalize closes the loop.
  class ExpensesController < Backend::BaseController
    STATUSES = %w[to_justify ignored].freeze
    # Bank fees and the like are not purchases: out of the default list.
    NOT_PURCHASES = %w[qonto_fee].freeze

    def index
      @status = STATUSES.include?(params[:status]) ? params[:status] : 'to_justify'
      @all_types = params[:all_types].present?
      scope = unjustified_lines.where(transfered_on: current_financial_year_range)
      scope = scope.where.not(transaction_nature: NOT_PURCHASES) unless @all_types
      @counts = { 'to_justify' => review_scope(scope, ignored: false).count, 'ignored' => review_scope(scope, ignored: true).count }
      @items = review_scope(scope, ignored: @status == 'ignored').includes(:attachments).order(transfered_on: :desc, id: :desc).limit(300).to_a
      @suggestions = @status == 'to_justify' ? Qonto::ExpenseSuggester.for_all(@items) : {}
      @elsewhere = unjustified_lines.where.not(transfered_on: current_financial_year_range).count if current_financial_year
    end

    def ignore
      set_review(find_item, 'ignored')
      notify_success(:expense_ignored.tl)
      redirect_to qonto_expenses_path
    end

    def restore
      set_review(find_item, nil)
      redirect_to qonto_expenses_path(status: 'ignored')
    end

    # Downloads, from Qonto, the files attached to this transaction (read only
    # on Qonto's side). The suggester reads them on the next display.
    def fetch_document
      item = find_item
      ids = Array((item.provider.to_h.with_indifferent_access[:data] || {})[:attachment_ids])
      if ids.empty?
        notify_warning(:expense_no_attachment_known.tl)
      elsif Qonto::DocumentsImportService.call(items: [item]).positive?
        notify_success(:expense_documents_fetched.tl)
      else
        notify_warning(:expense_documents_none_new.tl)
      end
      redirect_to qonto_expenses_path
    rescue StandardError => e
      Rails.logger.warn("[Qonto][expenses] fetch_document: #{e.class}: #{e.message}")
      notify_error(:expense_documents_failed.tl)
      redirect_to qonto_expenses_path
    end

    # Where the purchase form sends back after it created the purchase.
    def finalize
      result = Qonto::ExpenseFinalizer.call(find_item)
      case result.status
      when :done
        notify_success(:expense_purchase_created.tl(number: result.purchase.number))
        redirect_to backend_purchase_path(result.purchase)
      when :not_lettered
        notify_warning(:expense_not_lettered.tl)
        redirect_to qonto_expenses_path
      else
        notify_warning(:expense_purchase_not_found.tl)
        redirect_to qonto_expenses_path
      end
    end

    private

      def find_item
        BankStatementItem.of_provider_name('qonto', 'transaction').find(params[:id])
      end

      def unjustified_lines
        BankStatementItem.of_provider_name('qonto', 'transaction').where('bank_statement_items.debit > 0').where(letter: [nil, ''])
      end

      def current_financial_year_range
        year = current_financial_year
        year ? year.started_on..year.stopped_on : Date.new(1900)..Date.new(2999)
      end

      REVIEW_SQL = "bank_statement_items.provider->'data'->>'expense_review'"

      def review_scope(scope, ignored:)
        ignored ? scope.where("#{REVIEW_SQL} = 'ignored'") : scope.where("#{REVIEW_SQL} IS NULL OR #{REVIEW_SQL} <> 'ignored'")
      end

      # Only the jsonb is written: the line is bookkept, its figures must not move.
      def set_review(item, value)
        provider = (item.provider || {}).to_h
        key = provider.key?('data') ? 'data' : :data
        data = (provider[key] || {}).to_h.stringify_keys
        value ? data['expense_review'] = value : data.delete('expense_review')
        item.update_column(:provider, provider.merge(key => data))
      end
  end
end
