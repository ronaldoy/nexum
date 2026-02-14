class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path(**tenant_slug_path_params(params[:tenant_slug])), alert: "Tente novamente mais tarde." }

  def new
  end

  def create
    tenant_slug = normalized_tenant_slug(params[:tenant_slug])
    tenant_id = resolve_tenant_id_from_slug(tenant_slug)
    unless tenant_id
      redirect_to new_password_path(**tenant_slug_path_params(tenant_slug)), alert: "Organização não encontrada."
      return
    end

    bootstrap_database_tenant_context!(tenant_id)

    if user = User.find_by(email_address: params[:email_address])
      PasswordsMailer.reset(user, tenant_slug: tenant_slug).deliver_later
    end

    redirect_to new_session_path(**tenant_slug_path_params(tenant_slug)), notice: "Enviamos instruções para redefinição de senha (se houver usuário com esse e-mail)."
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path(tenant_slug: params[:tenant_slug]), notice: "A senha foi redefinida."
    else
      redirect_to edit_password_path(params[:token], tenant_slug: params[:tenant_slug]), alert: "As senhas não conferem."
    end
  end

  private
    def set_user_by_token
      tenant_slug = normalized_tenant_slug(params[:tenant_slug])
      tenant_id = resolve_tenant_id_from_slug(tenant_slug)
      unless tenant_id
        redirect_to new_password_path(**tenant_slug_path_params(tenant_slug)), alert: "Organização não encontrada."
        return
      end

      bootstrap_database_tenant_context!(tenant_id)
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path(**tenant_slug_path_params(tenant_slug)), alert: "O link de redefinição de senha é inválido ou expirou."
    end

    def normalized_tenant_slug(value)
      value.to_s.strip.downcase.presence
    end

    def tenant_slug_path_params(value)
      slug = normalized_tenant_slug(value)
      slug.present? ? { tenant_slug: slug } : {}
    end
end
