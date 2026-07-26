# frozen_string_literal: true

Rails.application.routes.draw do
  concern :list do
    get :list, on: :collection
  end

  concern :unroll do
    get :unroll, on: :collection
  end

  namespace :qonto do
    resource :qonto_synchronization, only: [] do
      get :perform
    end

    resources :inbound_invoices, only: %i[index] do
      member do
        post :ignore
        post :create_purchase
        post :attach_supplier
      end
    end

    resources :outbound_invoices, only: %i[index] do
      member { get :status }
    end
    post 'sales/:sale_id/send_einvoice', to: 'outbound_invoices#create', as: :send_sale_einvoice

    # Qonto webhook — no session/CSRF, HMAC-verified (see WebhooksController).
    post 'webhooks/client_invoices', to: 'webhooks#client_invoices'
  end
end
