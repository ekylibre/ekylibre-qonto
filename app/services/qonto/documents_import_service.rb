# frozen_string_literal: true

module Qonto
  class DocumentsImportService
    PROVIDER_VENDOR = 'qonto'
    PROVIDER_NAME = 'transaction'

    # transaction object
    #
    # side in [debit, credit]
    # operation_type in [income, transfer, card, direct_debit, qonto_fee, cheque, recall, swift_income]
    # category in [transport, online_service, subscription, food_and_grocery, restaurant_and_bar, other_income, hardware_and_equipment, other_service, utility, tax, salary, other_expense]
    # 
    # :transaction_id=>"ekylibre-8704-1-transaction-50",
    # :amount=>3.3,
    # :amount_cents=>330,
    # :settled_balance=>76873.08,
    # :settled_balance_cents=>7687308,
    # :attachment_ids=>[],
    # :local_amount=>3.3,
    # :local_amount_cents=>330,
    # :side=>"debit",
    # :operation_type=>"card",
    # :currency=>"EUR",
    # :local_currency=>"EUR",
    # :label=>"HORODATEURS BX",
    # :settled_at=>"2023-09-09T15:27:52.285Z",
    # :emitted_at=>"2023-09-08T09:58:31.082Z",
    # :updated_at=>"2023-09-09T16:31:15.278Z",
    # :status=>"completed",
    # :note=>nil,
    # :reference=>nil,
    # :vat_amount=>nil,
    # :vat_amount_cents=>nil,
    # :vat_rate=>nil,
    # :initiator_id=>"0a08e729-3bd2-4da0-8571-ea83fc93189f",
    # :label_ids=>[],
    # :attachment_lost=>false,
    # :attachment_required=>true,
    # :card_last_digits=>"5502",
    # :category=>"transport",
    # :id=>"6cbb638b-e428-49e0-b60b-8ba7567d144c",
    # :subject_type=>"Card"

    def self.call(*args)
      new(*args).call
    end

    def initialize(cash:)
      @cash = cash
    end

    def call
      BankStatementItem.of_provider_name(PROVIDER_VENDOR, PROVIDER_NAME).each do |bsi|
        if bsi.provider[:data]["attachment_ids"].any?
          bsi.provider[:data]["attachment_ids"].each do |id|
            attachment = get_attachment(id)
            link_document(bsi, attachment)
          end
        end
      end
    end

    private
      attr_reader :cash

      def get_attachment(id)
        Qonto::QontoIntegration.show_attachment(id).execute do |c|
          c.success do |list|
            list.to_struct.attachment.to_struct
          end
        end
      end

      def link_document(bsi, attachment)
        return nil if Document.find_by(key: attachment.id)

        doc = Document.new(key: attachment.id, name: attachment.file_name, file: URI.parse(attachment.url).open)
        bsi.attachments.create!(document: doc)
      end

  end
end
