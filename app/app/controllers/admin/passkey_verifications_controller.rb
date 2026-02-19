module Admin
  class PasskeyVerificationsController < ApplicationController
    REGISTRATION_CHALLENGE_KEY = :admin_webauthn_registration_challenge
    AUTHENTICATION_CHALLENGE_KEY = :admin_webauthn_authentication_challenge
    RETURN_TO_KEY = :admin_webauthn_return_to

    PASSKEY_REGISTERED_ACTION = "ADMIN_DASHBOARD_PASSKEY_REGISTERED".freeze
    PASSKEY_VERIFIED_ACTION = "ADMIN_DASHBOARD_PASSKEY_VERIFIED".freeze
    PASSKEY_FAILED_ACTION = "ADMIN_DASHBOARD_PASSKEY_FAILED".freeze

    before_action :ensure_ops_admin!

    def new
      return_to = safe_return_to(params[:return_to])
      session[RETURN_TO_KEY] = return_to

      if Current.session&.admin_webauthn_verified_recently?
        redirect_to return_to, notice: "Segundo fator já validado para o painel administrativo."
        return
      end

      @registered_credentials_count = current_user_credentials.count
      @return_to = return_to
    end

    def registration_options
      user = Current.user
      user_handle = user.ensure_webauthn_id!

      options = WebAuthn::Credential.options_for_create(
        user: {
          id: user_handle,
          name: user.email_address,
          display_name: user.email_address
        },
        exclude: current_user_credentials.pluck(:webauthn_id),
        authenticator_selection: {
          user_verification: "required"
        }
      )
      session[REGISTRATION_CHALLENGE_KEY] = options.challenge

      render json: options
    end

    def register
      credential = WebAuthn::Credential.from_create(public_key_credential_params.to_h)
      challenge = session.delete(REGISTRATION_CHALLENGE_KEY)
      raise WebAuthn::Error, "registration_challenge_missing" if challenge.blank?

      credential.verify(challenge, origin: request.base_url)

      record = current_user_credentials.create!(
        tenant_id: Current.user.tenant_id,
        webauthn_id: credential.id,
        public_key: credential.public_key,
        sign_count: credential.sign_count,
        nickname: "Chave de segurança #{Time.current.in_time_zone('America/Sao_Paulo').strftime('%d/%m/%Y %H:%M')}",
        last_used_at: Time.current
      )

      mark_admin_passkey_verified!(action_type: PASSKEY_REGISTERED_ACTION, target_id: record.id)

      render json: {
        data: {
          verified: true,
          registered: true,
          redirect_path: safe_return_to(session[RETURN_TO_KEY])
        }
      }, status: :created
    rescue ActiveRecord::RecordInvalid, WebAuthn::Error => error
      create_action_log!(action_type: PASSKEY_FAILED_ACTION, success: false, metadata: { flow: "register", error: error.message })
      render json: {
        error: {
          code: "passkey_registration_failed",
          message: "Não foi possível registrar a passkey para o painel administrativo."
        }
      }, status: :unprocessable_entity
    end

    def authentication_options
      credential_ids = current_user_credentials.pluck(:webauthn_id)
      if credential_ids.empty?
        render json: {
          error: {
            code: "passkey_not_registered",
            message: "Cadastre uma passkey antes de confirmar o segundo fator."
          }
        }, status: :unprocessable_entity
        return
      end

      options = WebAuthn::Credential.options_for_get(
        allow: credential_ids,
        user_verification: "required"
      )
      session[AUTHENTICATION_CHALLENGE_KEY] = options.challenge

      render json: options
    end

    def verify
      credential = WebAuthn::Credential.from_get(public_key_credential_params.to_h)
      challenge = session.delete(AUTHENTICATION_CHALLENGE_KEY)
      raise WebAuthn::Error, "authentication_challenge_missing" if challenge.blank?

      stored_credential = current_user_credentials.find_by!(webauthn_id: credential.id)

      credential.verify(
        challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        origin: request.base_url
      )

      stored_credential.update!(
        sign_count: credential.sign_count,
        last_used_at: Time.current
      )

      mark_admin_passkey_verified!(action_type: PASSKEY_VERIFIED_ACTION, target_id: stored_credential.id)

      render json: {
        data: {
          verified: true,
          redirect_path: safe_return_to(session[RETURN_TO_KEY])
        }
      }
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, WebAuthn::Error => error
      create_action_log!(action_type: PASSKEY_FAILED_ACTION, success: false, metadata: { flow: "verify", error: error.message })
      render json: {
        error: {
          code: "passkey_verification_failed",
          message: "Falha ao validar a passkey para o painel administrativo."
        }
      }, status: :unprocessable_entity
    end

    private

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def current_user_credentials
      @current_user_credentials ||= Current.user.webauthn_credentials.order(created_at: :asc)
    end

    def public_key_credential_params
      params.require(:public_key_credential).permit(
        :id,
        :type,
        :rawId,
        response: %i[
          attestationObject
          clientDataJSON
          authenticatorData
          signature
          userHandle
        ],
        clientExtensionResults: {}
      )
    end

    def safe_return_to(value)
      fallback = admin_dashboard_path
      candidate = value.to_s
      return fallback if candidate.blank?
      return fallback unless candidate.start_with?("/")
      return fallback if candidate.start_with?("//")

      candidate
    end

    def mark_admin_passkey_verified!(action_type:, target_id:)
      Current.session&.mark_admin_webauthn_verified!
      create_action_log!(action_type: action_type, success: true, target_id: target_id, target_type: "WebauthnCredential")
    end

    def create_action_log!(action_type:, success:, target_id: nil, target_type: nil, metadata: {})
      ActionIpLog.create!(
        tenant_id: Current.user.tenant_id,
        actor_party_id: Current.user.party_id,
        action_type: action_type,
        ip_address: request.remote_ip.presence || "0.0.0.0",
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.fullpath,
        http_method: request.method,
        channel: "ADMIN",
        target_type: target_type,
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: metadata
      )
    end
  end
end
