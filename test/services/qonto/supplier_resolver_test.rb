# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require_relative '../../support/qonto_lettering'

class Qonto::SupplierResolverTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  include QontoLettering

  setup do
    @mode = outgoing_payment_modes(:outgoing_payment_modes_001)
    @cash = @mode.cash
    @acme = entities(:entities_008)
    @other = entities(:entities_001)
  end

  def test_the_supplier_paid_for_the_same_label_before_is_found
    lettered_purchase(cash: @cash, mode: @mode, supplier: @acme, label: 'ACME SAS')
    item = unmatched_item(cash: @cash, label: 'ACME SAS', debit: 30)

    result = Qonto::SupplierResolver.new.resolve(item)

    assert_equal @acme, result.entity
    assert_equal :learned_label, result.how
    assert_equal 1, result.evidence
  end

  def test_the_label_is_compared_without_case_or_punctuation
    lettered_purchase(cash: @cash, mode: @mode, supplier: @acme, label: 'SumUp *La Popote')
    item = unmatched_item(cash: @cash, label: 'SUMUP  la popote', debit: 12)

    assert_equal @acme, Qonto::SupplierResolver.new.resolve(item).entity
  end

  def test_a_label_paid_to_two_suppliers_is_not_guessed
    lettered_purchase(cash: @cash, mode: @mode, supplier: @acme, label: 'AMAZON')
    lettered_purchase(cash: @cash, mode: @mode, supplier: @other, label: 'AMAZON')
    item = unmatched_item(cash: @cash, label: 'AMAZON', debit: 30)

    assert_nil Qonto::SupplierResolver.new.resolve(item)
  end

  def test_the_majority_wins_when_it_is_clear_enough
    4.times { lettered_purchase(cash: @cash, mode: @mode, supplier: @acme, label: 'AMAZON') }
    lettered_purchase(cash: @cash, mode: @mode, supplier: @other, label: 'AMAZON')
    item = unmatched_item(cash: @cash, label: 'AMAZON', debit: 30)

    result = Qonto::SupplierResolver.new.resolve(item)

    assert_equal @acme, result.entity
    assert_equal 5, result.evidence
  end

  def test_the_same_counterparty_account_is_enough_when_the_label_differs
    lettered_purchase(cash: @cash, mode: @mode, supplier: @acme, label: 'VIR ACME 1', iban: 'FR7610278022840002017740114')
    item = unmatched_item(cash: @cash, label: 'VIR ACME 2', debit: 30, data: { counterparty_iban: 'FR76 1027 8022 8400 0201 7740 114' })

    result = Qonto::SupplierResolver.new.resolve(item)

    assert_equal @acme, result.entity
    assert_equal :learned_iban, result.how
  end

  def test_an_entity_carrying_the_bank_account_is_found
    @acme.update_columns(iban: 'FR7610278022840002017740114')
    item = unmatched_item(cash: @cash, label: 'VIR 3', debit: 30, data: { counterparty_iban: 'FR7610278022840002017740114' })

    result = Qonto::SupplierResolver.new.resolve(item)

    assert_equal @acme, result.entity
    assert_equal :iban, result.how
  end

  def test_the_counterparty_name_of_one_entity_is_found
    item = unmatched_item(cash: @cash, label: 'CB 4521', debit: 30, data: { counterparty_name: @acme.full_name })

    result = Qonto::SupplierResolver.new.resolve(item)

    assert_equal @acme, result.entity
    assert_equal :name, result.how
  end

  def test_nothing_known_gives_nothing
    item = unmatched_item(cash: @cash, label: 'UNHEARD OF 99', debit: 30)

    assert_nil Qonto::SupplierResolver.new.resolve(item)
  end
end
