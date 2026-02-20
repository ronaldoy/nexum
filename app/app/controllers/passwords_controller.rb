class PasswordsController < ApplicationController
  PASSWORD_RESET_REQUESTED_ACTION = "PASSWORD_RESET_REQUESTED".freeze
  PASSWORD_RESET_COMPLETED_ACTION = "PASSWORD_RESET_COMPLETED".freeze
  PASSWORD_RESET_FAILED_ACTION = "PASSWORD_RESET_FAILED".freeze
  PASSWORD_RESET_TOKEN_INVALID_ACTION = "PASSWORD_RESET_TOKEN_INVALID".freeze

  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path(**tenant_slug_path_params(params[:tenant_slug])), alert: "Tente novamente mais tarde." }

  def new
  end

  def create
    tenant_slug, tenant_id = password_reset_tenant_context(params[:tenant_slug])
    return if performed?

    user = find_password_reset_user
    enqueue_password_reset(user:, tenant_slug:) if user.present?
    log_password_reset_requested(tenant_id:, tenant_slug:, user:)
    redirect_to_password_reset_confirmation(tenant_slug)
  end

  def edit
  end

  def update
    return handle_password_reset_success if @user.update(password_update_params)

    handle_password_reset_failure
  end

  private
  def set_user_by_token
    tenant_slug, tenant_id = password_reset_tenant_context(params[:tenant_slug])
    return if performed?

    @user = User.find_by_password_reset_token!(params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    log_invalid_password_reset_token(tenant_id:, tenant_slug:)
    redirect_to new_password_path(**tenant_slug_path_params(tenant_slug)), alert: "O link de redefinição de senha é inválido ou expirou."
  end

  def password_reset_tenant_context(raw_tenant_slug)
    tenant_slug = normalized_tenant_slug(raw_tenant_slug)
    tenant_id = resolve_tenant_id_from_slug(tenant_slug)

    unless tenant_id
      redirect_to new_password_path(**tenant_slug_path_params(tenant_slug)), alert: "Organização não encontrada."
      return [ nil, nil ]
    end

    bootstrap_database_tenant_context!(tenant_id)
    [ tenant_slug, tenant_id ]
  end

  def find_password_reset_user
    User.find_by(email_address: params[:email_address])
  end

  def enqueue_password_reset(user:, tenant_slug:)
    PasswordsMailer.reset(user, tenant_slug: tenant_slug).deliver_later
  end

  def log_password_reset_requested(tenant_id:, tenant_slug:, user:)
    create_password_action_log!(
      tenant_id: tenant_id,
      action_type: PASSWORD_RESET_REQUESTED_ACTION,
      success: true,
      actor_party_id: user&.party_id,
      target_type: "User",
      metadata: {
        tenant_slug: tenant_slug,
        user_found: user.present?,
        user_id: user&.id
      }
    )
  end

  def redirect_to_password_reset_confirmation(tenant_slug)
    redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)),
      notice: "Enviamos instruções para redefinição de senha (se houver usuário com esse e-mail)."
  end

  def handle_password_reset_success
    @user.sessions.destroy_all
    create_password_action_log!(
      tenant_id: @user.tenant_id,
      action_type: PASSWORD_RESET_COMPLETED_ACTION,
      success: true,
      actor_party_id: @user.party_id,
      target_type: "User",
      metadata: {
        tenant_slug: params[:tenant_slug].to_s,
        user_id: @user.id
      }
    )
    redirect_to new_session_path(tenant_slug: params[:tenant_slug]), notice: "A senha foi redefinida."
  end

  def handle_password_reset_failure
    create_password_action_log!(
      tenant_id: @user.tenant_id,
      action_type: PASSWORD_RESET_FAILED_ACTION,
      success: false,
      actor_party_id: @user.party_id,
      target_type: "User",
      metadata: {
        tenant_slug: params[:tenant_slug].to_s,
        user_id: @user.id,
        errors: @user.errors.full_messages
      }
    )
    redirect_to edit_password_path(params[:token], tenant_slug: params[:tenant_slug]), alert: "As senhas não conferem."
  end

  def password_update_params
    params.permit(:password, :password_confirmation)
  end

  def log_invalid_password_reset_token(tenant_id:, tenant_slug:)
    create_password_action_log!(
      tenant_id: tenant_id,
      action_type: PASSWORD_RESET_TOKEN_INVALID_ACTION,
      success: false,
      target_type: "User",
      metadata: { tenant_slug: tenant_slug }
    )
  end

  def normalized_tenant_slug(value)
    value.to_s.strip.downcase.presence
  end

  def tenant_slug_path_params(value)
    slug = normalized_tenant_slug(value)
    slug.present? ? { tenant_slug: slug } : {}
  end

  def create_password_action_log!(tenant_id:, action_type:, success:, actor_party_id: nil, target_id: nil, target_type: nil, metadata: {})
    return if tenant_id.blank?

    ActionIpLog.create!(password_action_log_attributes(
      tenant_id: tenant_id,
      actor_party_id: actor_party_id,
      action_type: action_type,
      success: success,
      target_id: target_id,
      target_type: target_type,
      metadata: metadata
    ))
  end

  def password_action_log_attributes(tenant_id:, actor_party_id:, action_type:, success:, target_id:, target_type:, metadata:)
    {
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
    }
  end
end
