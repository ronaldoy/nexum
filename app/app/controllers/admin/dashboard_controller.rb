module Admin
  class DashboardController < ApplicationController
    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!

    helper_method :ops_admin?

    def show
      snapshot = system_dashboard.call
      @generated_at = snapshot.fetch(:generated_at)
      @totals = snapshot.fetch(:totals)
      @tenant_rows = snapshot.fetch(:tenant_rows)
    end

    private

    def system_dashboard
      @system_dashboard ||= Admin::SystemDashboard.new(
        actor_id: Current.actor_id,
        role: Current.role
      )
    end

    def ops_admin?
      Current.user&.role == "ops_admin"
    end

    def ensure_ops_admin!
      deny_access! unless ops_admin?
    end

    def require_passkey_step_up!
      return if Current.session&.admin_webauthn_verified_recently?

      redirect_to new_admin_passkey_verification_path(return_to: request.fullpath),
        alert: "Confirme a passkey para acessar o painel administrativo."
    end

    def deny_access!
      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end
  end
end
