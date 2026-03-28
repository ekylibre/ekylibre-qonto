module Qonto
  class FetchTransactionsJob < ActiveJob::Base
    queue_as :default
    include Rails.application.routes.url_helpers

    def perform(cash_id:, user:)
      begin
        cash = Cash.find(cash_id)
        # get transactions for current cash aacounts
        Qonto::QontoIntegration.list_transactions(cash.iban).execute do |c|
          c.success do |list|
            transactions = list.to_struct.transactions.map(&:to_struct)
            Qonto::TransactionsImportService.call(cash: cash, transactions: transactions)
          end
        end
        # get document attach to current transactions in bsi for current cash aacounts
        Qonto::DocumentsImportService.call(cash: cash)
        user.notifications.create!(success_notification_params(cash))
      rescue StandardError => error
        Rails.logger.error $ERROR_INFO
        Rails.logger.error $ERROR_INFO.backtrace.join("\n")
        ExceptionNotifier.notify_exception($ERROR_INFO, data: { message: error })
        user.notifications.create!(error_notification_params(error))
      end
    end

    private

    def error_notification_params(error)
      {
        message: :error_during_transactions_synchronization.tl,
        level: :error,
        interpolations: {
          message: error
        }
      }
    end

      def success_notification_params(cash)
        {
          message: :cash_transactions_synchronized.tl,
          level: :success,
          interpolations: {
            cash_name: cash.name
          }
        }
      end
  end
end
