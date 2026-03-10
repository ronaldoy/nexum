module Admin
  class BaseController < ApplicationController
    include AdminPasskeyMode

    before_action :ensure_ops_admin!
    before_action :require_passkey_step_up!

    helper_method :admin_current_tenant

    private

    def admin_current_tenant
      @admin_current_tenant ||= Current.user&.tenant
    end

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de gestão FDIC."
    end

    def require_passkey_step_up!
      require_admin_passkey_step_up!(alert: "Confirme a passkey para acessar o cockpit FDIC.")
    end
  end
end
