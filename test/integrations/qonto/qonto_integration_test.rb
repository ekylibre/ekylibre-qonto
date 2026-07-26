# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# AC2 — list_transactions must follow Qonto pagination (meta.next_page) and
# return every transaction across all pages, not just the first one.
class QontoIntegrationTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  IBAN = 'FR7611111222223333333333391'

  setup do
    VCR.use_cassette('check_organization') do
      Integration.create!(nature: 'qonto', parameters: { client_id: 'cid', client_secret: 'sec' })
    end
  end

  def test_list_transactions_aggregates_every_page
    result = nil
    VCR.use_cassette('list_transactions_paginated') do
      Qonto::QontoIntegration.list_transactions(IBAN).execute do |c|
        c.success { |list| result = list }
      end
    end

    refute_nil result, 'the success block should have run'
    transactions = result[:transactions]
    assert_equal 3, transactions.size, 'transactions from both pages must be returned'
    assert_equal %w[q1 q2 q3], transactions.map { |t| t[:id] }
  end
end
