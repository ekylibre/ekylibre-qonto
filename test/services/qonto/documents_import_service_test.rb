# frozen_string_literal: true

require 'test_helper'

# AC3 — DocumentsImportService must only process the Qonto items of the cash it
# was given, not every Qonto item of the tenant. We assert this by capturing
# which attachment ids reach the (stubbed) Qonto API: only cash A's must appear.
class Qonto::DocumentsImportServiceTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  setup do
    @cash_a = cashes(:cashes_001)
    @cash_b = cashes(:cashes_002)
    create_qonto_item(@cash_a, provider_id: 'tx-a', attachment_ids: ['att-a'])
    create_qonto_item(@cash_b, provider_id: 'tx-b', attachment_ids: ['att-b'])
  end

  def test_only_processes_items_of_the_given_cash
    service = Qonto::DocumentsImportService.new(cash: @cash_a)

    requested_ids = []
    service.stub(:get_attachment, ->(id) { requested_ids << id; nil }) do
      service.call
    end

    assert_equal ['att-a'], requested_ids,
                 'only the attachment of cash A must be fetched — cash B must be untouched'
  end

  def test_only_the_given_lines_when_items_are_passed
    line = BankStatementItem.of_provider_name('qonto', 'transaction').find_by("provider ->> 'id' = 'tx-b'")
    service = Qonto::DocumentsImportService.new(items: [line])

    requested_ids = []
    service.stub(:get_attachment, ->(id) { requested_ids << id; nil }) do
      service.call
    end

    assert_equal ['att-b'], requested_ids
  end

  def test_a_document_already_known_is_attached_to_the_line_that_lacks_it
    line = BankStatementItem.of_provider_name('qonto', 'transaction').find_by("provider ->> 'id' = 'tx-b'")
    document = Document.create!(key: 'att-b', name: 'known.pdf', processable_attachment: false)
    service = Qonto::DocumentsImportService.new(items: [line])
    found = Struct.new(:id, :file_name, :url).new('att-b', 'known.pdf', nil)

    count = service.stub(:get_attachment, ->(_id) { found }) { service.call }

    assert_equal 1, count
    assert_equal [document.id], line.attachments.map(&:document_id)
    assert_equal 0, service.stub(:get_attachment, ->(_id) { found }) { service.call }, 'replaying attaches nothing more'
  end

  private

    def create_qonto_item(cash, provider_id:, attachment_ids:)
      statement = cash.bank_statements.create!(
        number: "#{cash.id}-2019-10",
        started_on: Date.new(2019, 10, 1),
        stopped_on: Date.new(2019, 10, 31)
      )
      statement.items.create!(
        name: "item #{provider_id}",
        transfered_on: Date.new(2019, 10, 15),
        credit: 10.0,
        provider: {
          vendor: 'qonto',
          name: 'transaction',
          id: provider_id,
          data: { attachment_ids: attachment_ids }
        }
      )
    end
end
