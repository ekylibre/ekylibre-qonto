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
  end
end
