class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path(**tenant_slug_path_params(params[:tenant_slug])), alert: "Tente novamente mais tarde." }

  def new
  end

  def create
    tenant_slug = normalized_tenant_slug(params[:tenant_slug])
    tenant_id = resolve_tenant_id_from_slug(tenant_slug)
    unless tenant_id
      redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), alert: "Organização não encontrada."
      return
    end

    bootstrap_database_tenant_context!(tenant_id)

    if user = User.authenticate_by(params.permit(:email_address, :password))
      unless mfa_verified_for?(user)
        redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), alert: mfa_error_message_for(user)
        return
      end

      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), alert: "Tente outro e-mail ou senha."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def mfa_verified_for?(user)
    return true unless user.mfa_required_for_role?

    user.valid_mfa_code?(params[:otp_code])
  end

  def mfa_error_message_for(user)
    return "MFA obrigatório para este perfil. Contate o suporte para habilitar." unless user.mfa_enabled?

    "Código MFA inválido."
  end

  def normalized_tenant_slug(value)
    value.to_s.strip.downcase.presence
  end

  def tenant_slug_path_params(value)
    slug = normalized_tenant_slug(value)
    slug.present? ? { tenant_slug: slug } : {}
  end
end
