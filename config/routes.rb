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
  end
end
