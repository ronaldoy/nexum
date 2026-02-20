class SessionsController < ApplicationController
  SESSION_AUTHENTICATED_ACTION = "SESSION_AUTHENTICATED".freeze
  SESSION_AUTHENTICATION_FAILED_ACTION = "SESSION_AUTHENTICATION_FAILED".freeze
  SESSION_MFA_FAILED_ACTION = "SESSION_MFA_FAILED".freeze
  SESSION_TERMINATED_ACTION = "SESSION_TERMINATED".freeze

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
        create_auth_action_log!(
          tenant_id: tenant_id,
          action_type: SESSION_MFA_FAILED_ACTION,
          success: false,
          actor_party_id: user.party_id,
          target_type: "User",
          metadata: {
            tenant_slug: tenant_slug,
            mfa_enabled: user.mfa_enabled?,
            user_id: user.id,
            user_uuid_id: user.uuid_id
          }
        )
        redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), alert: mfa_error_message_for(user)
        return
      end

      start_new_session_for user
        create_auth_action_log!(
          tenant_id: tenant_id,
          action_type: SESSION_AUTHENTICATED_ACTION,
          success: true,
          actor_party_id: user.party_id,
          target_type: "Session",
          metadata: {
            tenant_slug: tenant_slug,
            mfa_used: user.mfa_required_for_role?,
            session_id: Current.session&.id,
            user_id: user.id,
            user_uuid_id: user.uuid_id
          }
        )
      redirect_to after_authentication_url
    else
      create_auth_action_log!(
        tenant_id: tenant_id,
        action_type: SESSION_AUTHENTICATION_FAILED_ACTION,
        success: false,
        target_type: "UserCredential",
        metadata: { tenant_slug: tenant_slug }
      )
      redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), alert: "Tente outro e-mail ou senha."
    end
  end

  def destroy
    session_record = Current.session
    user = Current.user
    create_auth_action_log!(
      tenant_id: user&.tenant_id || session_record&.tenant_id,
      action_type: SESSION_TERMINATED_ACTION,
      success: true,
      actor_party_id: user&.party_id,
      target_type: "Session",
      metadata: {
        reason: "user_logout",
        session_id: session_record&.id,
        user_id: user&.id,
        user_uuid_id: user&.uuid_id
      }
    )
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

  def create_auth_action_log!(tenant_id:, action_type:, success:, actor_party_id: nil, target_id: nil, target_type: nil, metadata: {})
    return if tenant_id.blank?

    ActionIpLog.create!(
      tenant_id: tenant_id,
      actor_party_id: actor_party_id,
      action_type: action_type,
      ip_address: request.remote_ip.presence || "0.0.0.0",
      user_agent: request.user_agent,
      request_id: request.request_id,
      endpoint_path: request.fullpath,
      http_method: request.method,
      channel: "PORTAL",
      target_type: target_type,
      target_id: target_id,
      success: success,
      occurred_at: Time.current,
      metadata: metadata
    )
  end
end
