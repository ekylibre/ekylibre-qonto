require 'ekylibre-qonto/ext_navigation'

module EkylibreQonto
  class Engine < ::Rails::Engine
    initializer 'ekylibre-qonto.assets.precompile' do |app|
      app.config.assets.precompile += %w[integrations/qonto.png]
    end

    initializer 'ekylibre-qonto.i18n' do |app|
      app.config.i18n.load_path += Dir[EkylibreQonto::Engine.root.join('config', 'locales', '**', '*.yml')]
    end

    initializer 'ekylibre-qonto.extend_toolbar' do |_app|
      Ekylibre::View::Addon.add(:main_toolbar, 'backend/cashes/sync_qonto_bank_account_toolbar', to: 'backend/cashes#show')
    end

    initializer 'ekylibre-qonto.extend_navigation' do |_app|
      EkylibreQonto::ExtNavigation.add_navigation_xml_to_existing_tree
    end

    # Hourly reception of supplier e-invoices. HourlyTriggerJob publishes
    # :every_hour once per tenant, so the block runs in each tenant context.
    initializer 'ekylibre-qonto.schedule_inbound_fetch' do |_app|
      Ekylibre::Hook.subscribe(:every_hour) do
        Qonto::FetchInboundInvoicesJob.perform_later if Qonto::FetchInboundInvoicesJob.schedulable?
      end
    end
  end
end
