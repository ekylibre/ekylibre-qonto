require 'securerandom'

module Qonto
  class QontoSynchronizationsController < Backend::BaseController
    def perform
      cash_id = params[:cash_id]
      cash = Cash.find(cash_id)
      unless cash.synchronizable?
        notify_warning(:iban_should_be_provided.tl)
        redirect_to backend_cash_path(cash_id)
        return
      end

      Qonto::FetchTransactionsJob.perform_later(cash_id: cash_id, user: current_user)
      notify_success(:cash_transactions_synchronizing.tl)

      redirect_to backend_cash_path(cash_id)
    end
  end
end
