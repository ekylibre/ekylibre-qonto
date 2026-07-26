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

    # S1 — compliance banner: shown at the top of the pages where e-invoicing
    # reception matters, whenever the tenant is not connected to a PA.
    initializer 'ekylibre-qonto.einvoicing_banner' do |_app|
      %w[backend/sales#index backend/purchases#index qonto/inbound_invoices#index].each do |target|
        Ekylibre::View::Addon.add(:extensions_content_top, 'qonto/einvoicing_banner', to: target)
      end
    end

    # Hourly reception of supplier e-invoices. HourlyTriggerJob publishes
    # :every_hour once per tenant, so the block runs in each tenant context.
    initializer 'ekylibre-qonto.schedule_inbound_fetch' do |_app|
      Ekylibre::Hook.subscribe(:every_hour) do
        Qonto::FetchInboundInvoicesJob.perform_later if Qonto::FetchInboundInvoicesJob.schedulable?
      end
    end

    # S2 — emission button + lifecycle timeline cobble on the sale page.
    # The timeline's progressive-polling JS is inlined in the cobble partial
    # (no new Sprockets asset dir → no server restart to register it).
    initializer 'ekylibre-qonto.einvoicing_emission_toolbar' do |_app|
      Ekylibre::View::Addon.add(:main_toolbar, 'qonto/einvoicing_toolbar', to: 'backend/sales#show')
      Ekylibre::View::Addon.add(:cobbler, 'qonto/einvoicing_cobble', to: 'backend/sales#show')
    end

    # Hourly safety-net poll of in-progress emissions (webhook carries no
    # lifecycle detail, and the 204 does not guarantee progress).
    initializer 'ekylibre-qonto.poll_einvoices' do |_app|
      Ekylibre::Hook.subscribe(:every_hour) do
        Qonto::PollEInvoicesJob.perform_later if Qonto::FetchInboundInvoicesJob.schedulable?
      end
    end
  end
end
