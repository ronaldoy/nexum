Rails.application.routes.draw do
  resource :session, only: [ :new, :create, :destroy ]
  resources :passwords, param: :token, only: [ :new, :create, :edit, :update ]
  get "health" => "health#health"
  get "ready" => "health#ready"
  post "security/csp_reports" => "csp_reports#create"
  post "webhooks/escrow/:provider/:tenant_slug" => "webhooks/escrow#create", as: :webhooks_escrow
  get "docs/openapi/v1" => "openapi_docs#v1"
  get "docs/openapi/v1.yaml" => "openapi_docs#v1"

  namespace :api do
    namespace :v1 do
      post "oauth/token/:tenant_slug", to: "oauth/tokens#create", as: :oauth_token
      resources :hospital_organizations, only: %i[index]
      resources :physicians, only: %i[create show]
      resources :receivables, only: %i[index show create] do
        get :history, on: :member
        post :settle_payment, on: :member
        post :attach_document, on: :member
      end
      resources :kyc_profiles, only: %i[create show] do
        post :submit_document, on: :member
      end
      resources :anticipation_requests, only: %i[create] do
        post :issue_challenges, on: :member
        post :confirm, on: :member
      end
    end
  end

  namespace :admin do
    resource :passkey_verification, only: %i[new] do
      post :registration_options
      post :register
      post :authentication_options
      post :verify
    end

    get :dashboard, to: "dashboard#show"
    resources :api_access_tokens, only: %i[index create destroy]
    resources :partner_applications, only: %i[index create] do
      post :rotate_secret, on: :member
      patch :deactivate, on: :member
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "dashboard#show"
end
