# frozen_string_literal: true

require 'test_helper'

class Qonto::EInvoicingSettingsTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_state_predicates
    assert Qonto::EInvoicingSettings.new(:enabled).enabled?
    assert Qonto::EInvoicingSettings.new(:pending).pending?
    assert Qonto::EInvoicingSettings.new(:disabled).receiving_disabled?
    assert Qonto::EInvoicingSettings.new(:unavailable).receiving_disabled?
    refute Qonto::EInvoicingSettings.new(:enabled).receiving_disabled?
    refute Qonto::EInvoicingSettings.new(:unknown).receiving_disabled?
  end

  def test_without_integration_it_is_unavailable
    with_memory_cache do
      Integration.stub(:exists?, false) do
        assert Qonto::EInvoicingSettings.cached.receiving_disabled?
      end
    end
  end

  def test_with_integration_it_reads_the_real_api_state
    with_memory_cache do
      Integration.stub(:exists?, true) do
        stub_adapter(:enabled) do
          settings = Qonto::EInvoicingSettings.cached
          assert settings.enabled?
          refute settings.receiving_disabled?, 'a connected account must not show the banner'
        end
      end
    end
  end

  def test_with_integration_reporting_disabled_shows_the_banner
    with_memory_cache do
      Integration.stub(:exists?, true) do
        stub_adapter(:disabled) do
          assert Qonto::EInvoicingSettings.cached.receiving_disabled?
        end
      end
    end
  end

  def test_a_transient_api_failure_does_not_false_alarm
    with_memory_cache do
      Integration.stub(:exists?, true) do
        # the adapter maps an API failure to :unavailable
        stub_adapter(:unavailable) do
          settings = Qonto::EInvoicingSettings.cached
          assert_equal :unknown, settings.status
          refute settings.receiving_disabled?
        end
      end
    end
  end

  def test_cached_reads_from_cache_without_calling_the_api
    with_memory_cache do
      Rails.cache.write(Qonto::EInvoicingSettings.cache_key, :pending)
      assert Qonto::EInvoicingSettings.cached.pending?
    end
  end

  def test_refresh_writes_the_computed_status
    with_memory_cache do
      Integration.stub(:exists?, true) do
        stub_adapter(:enabled) { assert_equal :enabled, Qonto::EInvoicingSettings.refresh! }
      end
      assert_equal :enabled, Rails.cache.read(Qonto::EInvoicingSettings.cache_key)
    end
  end

  private

    def with_memory_cache
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) { yield }
    end

    def stub_adapter(status)
      fake = Object.new
      fake.define_singleton_method(:connection_status) { status }
      EInvoicing::Adapters::Qonto.stub(:new, fake) { yield }
    end
end
