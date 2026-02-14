# frozen_string_literal: true

class ActiveStorage::DirectUploadsController < ActiveStorage::BaseController
  ALLOWED_SCOPES = %w[receivables:documents:write kyc:write documents:upload].freeze
  DEFAULT_ALLOWED_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
  ].freeze
  DEFAULT_MAX_UPLOAD_BYTES = 25.megabytes

  before_action :authenticate_direct_upload_actor!
  before_action :enforce_upload_limits!
  skip_forgery_protection

  def create
    blob = ActiveStorage::Blob.create_before_direct_upload!(**blob_args)
    render json: direct_upload_json(blob)
  end

  private

  def authenticate_direct_upload_actor!
    return if authenticate_from_session!
    return if authenticate_from_api_token!

    render_unauthorized
  end

  def authenticate_from_session!
    session_id = cookies.encrypted[:session_id]
    tenant_id = cookies.encrypted[:session_tenant_id]
    return false if session_id.blank? || tenant_id.blank?

    with_database_tenant_context(tenant_id) do
      session = Session.find_by(id: session_id, tenant_id: tenant_id)
      return false if session.blank? || session.expired?
      return false if session.ip_address.present? && session.ip_address != request.remote_ip
      return false if session.user_agent.present? && session.user_agent != request.user_agent.to_s

      user = session.user
      return false if user.blank? || user.tenant_id.to_s != tenant_id.to_s

      @current_tenant_id = tenant_id.to_s
      @current_actor_party_id = user.party_id&.to_s
      true
    end
  end

  def authenticate_from_api_token!
    raw_token = bearer_token
    tenant_id = ApiAccessToken.tenant_id_from_token(raw_token)
    return false if tenant_id.blank?

    with_database_tenant_context(tenant_id) do
      token = ApiAccessToken.authenticate(raw_token)
      return false if token.blank?
      return false if (Array(token.scopes) & ALLOWED_SCOPES).empty?

      token.touch_last_used!
      @current_tenant_id = token.tenant_id.to_s
      @current_actor_party_id = token.user&.party_id&.to_s
      true
    end
  end

  def bearer_token
    scheme, value = request.authorization.to_s.split(" ", 2)
    return nil unless scheme&.casecmp("Bearer")&.zero?

    value&.strip
  end

  def enforce_upload_limits!
    blob = params[:blob]
    unless blob.is_a?(ActionController::Parameters) || blob.is_a?(Hash)
      render json: { error: { code: "invalid_blob_payload", message: "blob payload is required." } }, status: :unprocessable_entity
      return
    end

    byte_size = blob[:byte_size].to_i
    if byte_size <= 0 || byte_size > max_upload_bytes
      render json: { error: { code: "file_too_large", message: "File exceeds upload size limit." } }, status: :content_too_large
      return
    end

    content_type = blob[:content_type].to_s.downcase
    unless allowed_content_types.include?(content_type)
      render json: { error: { code: "invalid_content_type", message: "File content type is not allowed." } }, status: :unprocessable_entity
    end
  end

  def blob_args
    args = params.expect(blob: [:filename, :byte_size, :checksum, :content_type, metadata: {}]).to_h.symbolize_keys
    metadata = args[:metadata].is_a?(Hash) ? args[:metadata] : {}

    args.merge(
      metadata: metadata.merge(
        "tenant_id" => @current_tenant_id.to_s,
        "actor_party_id" => @current_actor_party_id.to_s,
        "uploaded_at" => Time.current.utc.iso8601(6)
      )
    )
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

  def render_unauthorized
    render json: {
      error: {
        code: "invalid_token",
        message: "Authentication token is invalid or expired."
      }
    }, status: :unauthorized
  end

  def with_database_tenant_context(tenant_id)
    ActiveRecord::Base.connection_pool.with_connection do
      ActiveRecord::Base.transaction(requires_new: true) do
        ActiveRecord::Base.connection.raw_connection.exec_params(
          "SELECT set_config($1, $2, true)",
          ["app.tenant_id", tenant_id.to_s]
        )
        yield
      end
    end
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
    false
  end
end
