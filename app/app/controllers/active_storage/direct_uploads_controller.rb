# frozen_string_literal: true

require "digest"

class ActiveStorage::DirectUploadsController < ActiveStorage::BaseController
  ALLOWED_SCOPES = %w[receivables:documents:write kyc:write documents:upload].freeze
  DEFAULT_ACTOR_ROLE = "integration_api".freeze
  IDEMPOTENCY_KEY_HEADER = "Idempotency-Key".freeze
  DEFAULT_ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
  ].freeze
  DEFAULT_MAX_UPLOAD_BYTES = 25.megabytes

  before_action :authenticate_direct_upload_actor!
  before_action :require_idempotency_key!
  before_action :enforce_upload_limits!
  skip_forgery_protection

  def create
    payload_hash = direct_upload_payload_hash

    with_actor_database_context { process_direct_upload(payload_hash: payload_hash) }
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
    render_context_unavailable
  end

  private

  def with_actor_database_context(&block)
    with_database_context(
      tenant_id: @current_tenant_id,
      actor_id: @current_actor_party_id,
      role: @current_actor_role,
      &block
    )
  end

  def process_direct_upload(payload_hash:)
    existing_blob = find_idempotent_blob
    return render_existing_idempotent_blob(existing_blob, payload_hash) if existing_blob.present?

    blob = create_direct_upload_blob!(payload_hash:)
    render_direct_upload(blob:, replayed: false)
  rescue ActiveRecord::RecordNotUnique
    replay_after_unique_violation(payload_hash:)
  end

  def create_direct_upload_blob!(payload_hash:)
    ActiveStorage::Blob.create_before_direct_upload!(**blob_args(payload_hash: payload_hash))
  end

  def replay_after_unique_violation(payload_hash:)
    existing_blob = find_idempotent_blob
    raise ActiveRecord::RecordNotFound, "idempotent blob not found after unique violation" if existing_blob.blank?

    render_existing_idempotent_blob(existing_blob, payload_hash)
  end

  def authenticate_direct_upload_actor!
    return if authenticate_from_session!
    return if authenticate_from_api_token!

    render_unauthorized
  end

  def authenticate_from_session!
    session_id, tenant_id = session_cookie_values
    return false if session_id.blank? || tenant_id.blank?

    with_database_tenant_context(tenant_id) do
      session = find_session(session_id:, tenant_id:)
      return false unless valid_session_record?(session)
      user = session.user
      return false unless valid_session_user?(user, tenant_id)

      assign_actor_from_session(tenant_id:, user:)
      true
    end
  end

  def authenticate_from_api_token!
    raw_token = bearer_token
    tenant_id = ApiAccessToken.tenant_id_from_token(raw_token)
    return false if tenant_id.blank?

    with_database_tenant_context(tenant_id) do
      token = ApiAccessToken.authenticate(raw_token)
      return false unless token_authenticated_for_direct_upload?(token)

      token.touch_last_used!
      assign_actor_from_token(token)
      true
    end
  end

  def session_cookie_values
    [ cookies.encrypted[:session_id], cookies.encrypted[:session_tenant_id] ]
  end

  def find_session(session_id:, tenant_id:)
    Session.includes(:user).find_by(id: session_id, tenant_id: tenant_id)
  end

  def valid_session_record?(session)
    return false if session.blank? || session.expired?
    return false if session.ip_address.present? && session.ip_address != request.remote_ip
    return false if session.user_agent.present? && session.user_agent != request.user_agent.to_s

    true
  end

  def valid_session_user?(user, tenant_id)
    user.present? && user.tenant_id.to_s == tenant_id.to_s
  end

  def assign_actor_from_session(tenant_id:, user:)
    @current_tenant_id = tenant_id.to_s
    @current_actor_party_id = user.party_id&.to_s
    @current_actor_role = user.role.to_s
  end

  def token_authenticated_for_direct_upload?(token)
    return false if token.blank?

    (Array(token.scopes) & ALLOWED_SCOPES).present?
  end

  def assign_actor_from_token(token)
    token_user = token.user
    @current_tenant_id = token.tenant_id.to_s
    @current_actor_party_id = token_user&.party_id&.to_s
    @current_actor_role = token_user&.role.to_s.presence || DEFAULT_ACTOR_ROLE
  end

  def bearer_token
    scheme, value = request.authorization.to_s.split(" ", 2)
    return nil unless scheme&.casecmp("Bearer")&.zero?

    value&.strip
  end

  def enforce_upload_limits!
    blob = params[:blob]
    return render_invalid_blob_payload unless valid_blob_payload?(blob)
    return render_file_too_large unless valid_upload_size?(blob)
    render_invalid_content_type unless valid_upload_content_type?(blob)
  end

  def require_idempotency_key!
    @idempotency_key = request.headers[IDEMPOTENCY_KEY_HEADER].to_s.strip
    return if @idempotency_key.present?

    render json: {
      error: {
        code: "missing_idempotency_key",
        message: "Idempotency-Key header is required for mutating requests."
      }
    }, status: :unprocessable_entity
  end

  def direct_upload_payload_hash
    digest_payload = normalized_digest_payload
    Digest::SHA256.hexdigest(digest_payload.to_json)
  end

  def normalized_digest_payload
    blob = params.expect(blob: [ :filename, :byte_size, :checksum, :content_type, metadata: {} ])

    {
      filename: blob[:filename].to_s,
      byte_size: blob[:byte_size].to_i,
      checksum: blob[:checksum].to_s,
      content_type: blob[:content_type].to_s.downcase
    }
  end

  def blob_args(payload_hash:)
    args = params.expect(blob: [ :filename, :byte_size, :checksum, :content_type, metadata: {} ]).to_h.symbolize_keys
    metadata = args[:metadata].is_a?(Hash) ? args[:metadata] : {}

    args.merge(
      metadata: metadata.merge(
        "tenant_id" => @current_tenant_id.to_s,
        "actor_party_id" => @current_actor_party_id.to_s,
        "direct_upload_idempotency_key" => @idempotency_key,
        "direct_upload_payload_hash" => payload_hash,
        "uploaded_at" => Time.current.utc.iso8601(6)
      )
    )
  end

  def find_idempotent_blob
    ActiveStorage::Blob
      .where(
        "app_active_storage_blob_tenant_id(metadata) = CAST(:tenant_id AS uuid) AND app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key' = :idempotency_key",
        tenant_id: @current_tenant_id.to_s,
        idempotency_key: @idempotency_key
      )
      .order(created_at: :desc)
      .first
  end

  def render_existing_idempotent_blob(existing_blob, payload_hash)
    existing_payload_hash = existing_blob.metadata&.dig("direct_upload_payload_hash").to_s
    if existing_payload_hash.present? && existing_payload_hash != payload_hash
      return render json: {
        error: {
          code: "idempotency_key_reused_with_different_payload",
          message: "Idempotency-Key was already used with a different direct upload payload."
        }
      }, status: :conflict
    end

    render_direct_upload(blob: existing_blob, replayed: true)
  end

  def render_direct_upload(blob:, replayed:)
    render json: direct_upload_json(blob).merge("replayed" => replayed)
  end

  def direct_upload_json(blob)
    blob.as_json(root: false, methods: :signed_id).merge(
      direct_upload: {
        url: blob.service_url_for_direct_upload,
        headers: blob.service_headers_for_direct_upload
      }
    )
  end

  def allowed_content_types
    configured = Rails.app.creds.option(:security, :direct_upload_allowed_content_types, default: ENV["DIRECT_UPLOAD_ALLOWED_CONTENT_TYPES"])
    values = Array(configured).flat_map { |value| value.to_s.split(",") }.map { |value| value.strip.downcase }.reject(&:blank?)
    values.presence || DEFAULT_ALLOWED_CONTENT_TYPES
  end

  def max_upload_bytes
    configured = Rails.app.creds.option(:security, :direct_upload_max_bytes, default: ENV["DIRECT_UPLOAD_MAX_BYTES"])
    return configured.to_i if configured.to_i.positive?

    DEFAULT_MAX_UPLOAD_BYTES
  end

  def valid_blob_payload?(blob)
    blob.is_a?(ActionController::Parameters) || blob.is_a?(Hash)
  end

  def valid_upload_size?(blob)
    byte_size = blob[:byte_size].to_i
    byte_size.positive? && byte_size <= max_upload_bytes
  end

  def valid_upload_content_type?(blob)
    allowed_content_types.include?(blob[:content_type].to_s.downcase)
  end

  def render_invalid_blob_payload
    render json: { error: { code: "invalid_blob_payload", message: "blob payload is required." } }, status: :unprocessable_entity
  end

  def render_file_too_large
    render json: { error: { code: "file_too_large", message: "File exceeds upload size limit." } }, status: :content_too_large
  end

  def render_invalid_content_type
    render json: { error: { code: "invalid_content_type", message: "File content type is not allowed." } }, status: :unprocessable_entity
  end

  def render_unauthorized
    render json: {
      error: {
        code: "invalid_token",
        message: "Authentication token is invalid or expired."
      }
    }, status: :unauthorized
  end

  def render_context_unavailable
    render json: {
      error: {
        code: "request_context_unavailable",
        message: "Authentication context could not be established."
      }
    }, status: :service_unavailable
  end

  def with_database_tenant_context(tenant_id, actor_id: nil, role: nil)
    with_database_context(tenant_id:, actor_id:, role:) do
      yield
    end
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
    false
  end

  def with_database_context(tenant_id:, actor_id: nil, role: nil)
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction(requires_new: true) do
        set_database_context!("app.tenant_id", tenant_id)
        set_database_context!("app.actor_id", actor_id)
        set_database_context!("app.role", role)
        yield
      end
    end
  end

  def set_database_context!(key, value)
    ActiveRecord::Base.connection.raw_connection.exec_params(
      "SELECT set_config($1, $2, true)",
      [ key.to_s, value.to_s ]
    )
  end
end
