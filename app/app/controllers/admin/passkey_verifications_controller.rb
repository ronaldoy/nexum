module Admin
  class PasskeyVerificationsController < ApplicationController
    include AdminPasskeyMode

    REGISTRATION_CHALLENGE_KEY = :admin_webauthn_registration_challenge
    AUTHENTICATION_CHALLENGE_KEY = :admin_webauthn_authentication_challenge
    RETURN_TO_KEY = :admin_webauthn_return_to
    PUBLIC_KEY_REQUIRED_FIELDS = %w[id type rawId].freeze
    PUBLIC_KEY_RESPONSE_FIELDS = %w[
      attestationObject
      clientDataJSON
      authenticatorData
      signature
      userHandle
      transports
      publicKeyAlgorithm
      publicKey
    ].freeze
    REGISTRATION_RESPONSE_FIELDS = %w[attestationObject clientDataJSON].freeze
    AUTHENTICATION_RESPONSE_FIELDS = %w[authenticatorData clientDataJSON signature].freeze

    PASSKEY_REGISTERED_ACTION = "ADMIN_DASHBOARD_PASSKEY_REGISTERED".freeze
    PASSKEY_VERIFIED_ACTION = "ADMIN_DASHBOARD_PASSKEY_VERIFIED".freeze
    PASSKEY_FAILED_ACTION = "ADMIN_DASHBOARD_PASSKEY_FAILED".freeze

    before_action :ensure_ops_admin!

    def new
      return_to = safe_return_to(params[:return_to])
      session[RETURN_TO_KEY] = return_to

      if demo_admin_passkey_bypass_enabled?
        Current.session&.mark_admin_webauthn_verified!
        redirect_to return_to, notice: "Passkey desativada no modo demo."
        return
      end

      if Current.session&.admin_webauthn_verified_recently?
        redirect_to return_to, notice: "Segundo fator já validado para o painel administrativo."
        return
      end

      @registered_credentials_count = current_user_credentials.count
      @return_to = return_to
    end

    def registration_options
      options = registration_options_payload
      session[REGISTRATION_CHALLENGE_KEY] = options.challenge

      render json: options
    end

    def register
      record = register_passkey!
      mark_admin_passkey_verified!(action_type: PASSKEY_REGISTERED_ACTION, target_id: record.id)
      render_register_success
    rescue ActiveRecord::RecordInvalid, WebAuthn::Error => error
      render_passkey_failure(
        flow: "register",
        error: error,
        code: "passkey_registration_failed",
        message: "Não foi possível registrar a passkey para o painel administrativo."
      )
    end

    def authentication_options
      credential_ids = current_user_credential_ids
      return render_passkey_not_registered if credential_ids.empty?

      options = request_relying_party.options_for_authentication(
        allow: credential_ids,
        user_verification: "required"
      )
      session[AUTHENTICATION_CHALLENGE_KEY] = options.challenge

      render json: options
    end

    def verify
      stored_credential = verify_passkey!
      mark_admin_passkey_verified!(action_type: PASSKEY_VERIFIED_ACTION, target_id: stored_credential.id)
      render_verify_success
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, WebAuthn::Error => error
      render_passkey_failure(
        flow: "verify",
        error: error,
        code: "passkey_verification_failed",
        message: "Falha ao validar a passkey para o painel administrativo."
      )
    end

    private

    def ensure_ops_admin!
      return if Current.user&.role == "ops_admin"

      redirect_to root_path, alert: "Acesso restrito ao perfil de operação."
    end

    def current_user_credentials
      @current_user_credentials ||= Current.user.webauthn_credentials.order(created_at: :asc)
    end

    def current_user_credential_ids
      current_user_credentials.pluck(:webauthn_id)
    end

    def registration_options_payload
      user = Current.user
      user_handle = user.ensure_webauthn_id!

      request_relying_party.options_for_registration(
        user: registration_user_payload(user:, user_handle:),
        exclude: current_user_credential_ids,
        authenticator_selection: { user_verification: "required" }
      )
    end

    def registration_user_payload(user:, user_handle:)
      {
        id: user_handle,
        name: user.email_address,
        display_name: user.email_address
      }
    end

    def register_passkey!
      credential = request_relying_party.verify_registration(
        public_key_credential_payload!(required_response_fields: REGISTRATION_RESPONSE_FIELDS),
        registration_challenge!
      )
      create_passkey_record(credential)
    end

    def registration_challenge!
      challenge = session.delete(REGISTRATION_CHALLENGE_KEY)
      raise WebAuthn::Error, "registration_challenge_missing" if challenge.blank?

      challenge
    end

    def create_passkey_record(credential)
      current_user_credentials.create!(
        tenant_id: Current.user.tenant_id,
        webauthn_id: credential.id,
        public_key: credential.public_key,
        sign_count: credential.sign_count,
        nickname: passkey_nickname,
        last_used_at: Time.current
      )
    end

    def passkey_nickname
      "Chave de segurança #{Time.current.in_time_zone('America/Sao_Paulo').strftime('%d/%m/%Y %H:%M')}"
    end

    def verify_passkey!
      credential, stored_credential = request_relying_party.verify_authentication(
        public_key_credential_payload!(required_response_fields: AUTHENTICATION_RESPONSE_FIELDS),
        authentication_challenge!
      ) do |webauthn_credential|
        current_user_credentials.find_by!(webauthn_id: webauthn_credential.id)
      end

      stored_credential.update!(sign_count: credential.sign_count, last_used_at: Time.current)
      stored_credential
    end

    def authentication_challenge!
      challenge = session.delete(AUTHENTICATION_CHALLENGE_KEY)
      raise WebAuthn::Error, "authentication_challenge_missing" if challenge.blank?

      challenge
    end

    def render_register_success
      render json: { data: passkey_success_payload(registered: true) }, status: :created
    end

    def render_verify_success
      render json: { data: passkey_success_payload }
    end

    def passkey_success_payload(registered: false)
      payload = {
        verified: true,
        redirect_path: safe_return_to(session[RETURN_TO_KEY])
      }
      payload[:registered] = true if registered
      payload
    end

    def render_passkey_not_registered
      render json: {
        error: {
          code: "passkey_not_registered",
          message: "Cadastre uma passkey antes de confirmar o segundo fator."
        }
      }, status: :unprocessable_entity
    end

    def render_passkey_failure(flow:, error:, code:, message:)
      create_action_log!(action_type: PASSKEY_FAILED_ACTION, success: false, metadata: { flow: flow, error: error.message })
      render json: { error: { code: code, message: message } }, status: :unprocessable_entity
    end

    def public_key_credential_payload!(required_response_fields:)
      credential = normalize_hash(params.require(:public_key_credential))
      normalized_payload = {
        "id" => credential["id"],
        "type" => credential["type"],
        "rawId" => credential["rawId"],
        "authenticatorAttachment" => credential["authenticatorAttachment"],
        "clientExtensionResults" => normalize_hash(credential["clientExtensionResults"]),
        "response" => normalize_hash(credential["response"]).slice(*PUBLIC_KEY_RESPONSE_FIELDS)
      }

      missing_fields = PUBLIC_KEY_REQUIRED_FIELDS.select { |field| normalized_payload[field].blank? }
      missing_fields.concat(
        required_response_fields.select { |field| normalized_payload.dig("response", field).blank? }
      )

      if missing_fields.any?
        raise WebAuthn::Error, "invalid_public_key_credential_payload: #{missing_fields.join(',')}"
      end

      normalized_payload
    end

    def normalize_hash(value)
      return {} unless value.respond_to?(:to_unsafe_h) || value.respond_to?(:to_h)

      raw_hash = if value.respond_to?(:to_unsafe_h)
        value.to_unsafe_h
      else
        value.to_h
      end

      raw_hash.deep_stringify_keys
    end

    def request_relying_party
      @request_relying_party ||= begin
        base_relying_party = WebAuthn.configuration.relying_party

        WebAuthn::RelyingParty.new(
          algorithms: Array(base_relying_party.algorithms).dup,
          encoding: base_relying_party.encoding,
          allowed_origins: [ request.base_url ],
          id: request.host,
          name: base_relying_party.name,
          verify_attestation_statement: base_relying_party.verify_attestation_statement,
          credential_options_timeout: base_relying_party.credential_options_timeout,
          silent_authentication: base_relying_party.silent_authentication,
          acceptable_attestation_types: Array(base_relying_party.acceptable_attestation_types).dup,
          attestation_root_certificates_finders: base_relying_party.attestation_root_certificates_finders,
          legacy_u2f_appid: base_relying_party.legacy_u2f_appid
        )
      end
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
      ActionIpLog.create!(action_log_attributes(
        action_type: action_type,
        success: success,
        target_id: target_id,
        target_type: target_type,
        metadata: metadata
      ))
    end

    def action_log_attributes(action_type:, success:, target_id:, target_type:, metadata:)
      {
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
      }
    end
  end
end
