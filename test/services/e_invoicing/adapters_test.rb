# frozen_string_literal: true

# Standalone unit test for the e-invoicing port adapters (Fake / Null).
# These adapters touch neither the DB nor the network, so this runs without
# booting Rails:  ruby -Itest test/services/e_invoicing/adapters_test.rb
require 'minitest/autorun'

root = File.expand_path('../../../../app/services/e_invoicing', __FILE__)
require File.join(root, 'gateway')
require File.join(root, 'adapters', 'null')
require File.join(root, 'adapters', 'fake')

module EInvoicing
  class AdaptersTest < Minitest::Test
    Sale = Struct.new(:client)
    Entity = Struct.new(:id)

    # ---- Null adapter (AC6) ------------------------------------------------

    def test_null_degrades_without_raising
      null = Adapters::Null.new
      assert_equal :unavailable, null.connection_status
      assert_equal :unknown, null.recipient_reachable?(Entity.new(1))
      assert_equal [], null.lifecycle('whatever')
      assert_equal [], null.inbound_since(nil)

      result = null.submit(Sale.new(Entity.new(1)))
      refute result.ok?
      assert_equal :not_configured, result.error_code
    end

    # ---- Fake adapter — nominal lifecycle 200 → 201 → 202 (AC5) ------------

    def test_fake_drives_submitted_issued_received
      fake = Adapters::Fake.new(reachable: true)
      result = fake.submit(Sale.new(Entity.new(42)))

      assert result.ok?
      remote_id = result.value
      assert_equal %w[200], codes(fake.lifecycle(remote_id))

      fake.advance(remote_id)
      assert_equal %w[200 201], codes(fake.lifecycle(remote_id))

      fake.advance(remote_id)
      assert_equal %w[200 201 202], codes(fake.lifecycle(remote_id))

      # No progression beyond "received".
      assert_equal %w[200 201 202], codes(fake.advance(remote_id))
      # occurred_at ticks are monotonic.
      ticks = fake.lifecycle(remote_id).map { |e| e[:occurred_at] }
      assert_equal ticks.sort, ticks
    end

    # ---- Fake adapter — failure path (AC5) --------------------------------

    def test_fake_submit_fails_when_recipient_unreachable
      fake = Adapters::Fake.new(reachable: false)
      result = fake.submit(Sale.new(Entity.new(7)))

      refute result.ok?
      assert_equal 'recipient_not_reachable_on_einvoicing', result.error_code
      assert_empty fake.lifecycle('fake-einvoice-1')
    end

    def test_fake_reachability_per_entity
      fake = Adapters::Fake.new(reachable: { 1 => true, 2 => false })
      assert_equal true, fake.recipient_reachable?(Entity.new(1))
      assert_equal false, fake.recipient_reachable?(Entity.new(2))
      assert_equal :unknown, fake.recipient_reachable?(Entity.new(99))
    end

    def test_fake_advance_unknown_id_returns_nil
      assert_nil Adapters::Fake.new.advance('nope')
    end

    def test_fake_inbound_stub_and_filter
      fake = Adapters::Fake.new.stub_inbound([{ remote_id: 'a', updated_at: 10 },
                                              { remote_id: 'b', updated_at: 30 }])
      assert_equal %w[a b], fake.inbound_since.map { |i| i[:remote_id] }
      assert_equal %w[b], fake.inbound_since(20).map { |i| i[:remote_id] }
    end

    # ---- Result value object ----------------------------------------------

    def test_result_helpers
      ok = Gateway::Result.success('X')
      assert ok.ok?
      assert_equal 'X', ok.value

      ko = Gateway::Result.failure(:boom, 'detail')
      refute ko.ok?
      assert_equal :boom, ko.error_code
      assert_equal 'detail', ko.error_detail
    end

    private

      def codes(events)
        events.map { |e| e[:code] }
      end
  end
end
