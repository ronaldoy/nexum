require "digest"
require "json"

module Webhooks
  class EscrowController < ActionController::API
    include RequestContext

    EVENT_ID_HEADER_CANDIDATES = %w[
      X-Webhook-Id
      X-Request-Id
      X-QITECH-Event-Id
      X-STARKBANK-Event-Id
    ].freeze

    WebhookContext = Struct.new(
      :provider,
      :raw_body,
      :payload,
      :payload_sha256,
      :signature,
      :provider_event_id,
      keyword_init: true
    ) do
      def event_type
        payload["event_type"].to_s.presence || payload["type"].to_s.presence
      end
    end

    WebhookOutcome = Struct.new(:result, :receipt, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end

    class WebhookError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        @code = code
        super(message)
      end
    end

    class BadRequestError < WebhookError; end
    class ConflictError < WebhookError; end

    rescue_from RequestContext::ContextError, with: :render_context_unavailable
    rescue_from Integrations::Escrow::Webhooks::AuthenticateRequest::Error, with: :render_authentication_error
    rescue_from JSON::ParserError, with: :render_invalid_json
    rescue_from WebhookError, with: :render_webhook_error

    def create
      context = build_webhook_context
      return unless tenant_context_available?
      outcome = process_webhook!(context)

      capture_ignored_reconciliation_exception!(context:, outcome:)
      return render_replayed_webhook(context:, receipt: outcome.receipt) if outcome.replayed?

      render_processed_webhook(context:, outcome:)
    rescue Integrations::Escrow::Error => error
      handle_integration_error(error:, context:)
    rescue ActiveRecord::RecordInvalid => error
      render_unprocessable(
        code: "webhook_receipt_invalid",
        message: error.record.errors.full_messages.to_sentence
      )
    rescue ActiveRecord::RecordNotUnique
      handle_record_not_unique(context:)
    end

    private

    def tenant_context_available?
      return true if Current.tenant_id.present?

      render json: {
        error: {
          code: "webhook_signature_invalid",
          message: "Webhook signature is invalid.",
          request_id: request.request_id
        }
      }, status: :unauthorized
      false
    end

    def build_webhook_context
      provider = Integrations::Escrow::ProviderConfig.normalize_provider(params[:provider])
      raw_body = request.raw_post.to_s
      payload = parse_payload!(raw_body)
      payload_sha256 = Digest::SHA256.hexdigest(raw_body)
      signature = authenticate_signature!(provider:, raw_body:)
      provider_event_id = resolve_provider_event_id(payload:, payload_sha256:)

      WebhookContext.new(
        provider: provider,
        raw_body: raw_body,
        payload: payload,
        payload_sha256: payload_sha256,
        signature: signature,
        provider_event_id: provider_event_id
      )
    end

    def process_webhook!(context)
      result = nil
      receipt = nil
      replayed = false

      ActiveRecord::Base.transaction do
        existing = find_existing_receipt(context)
        if existing
          ensure_matching_payload!(existing:, payload_sha256: context.payload_sha256)
          replayed = true
          receipt = existing
        else
          result = reconcile_webhook!(context)
          receipt = create_processed_receipt!(context:, result:)
        end
      end

      WebhookOutcome.new(result:, receipt:, replayed:)
    end

    def find_existing_receipt(context)
      ProviderWebhookReceipt.lock.find_by(
        tenant_id: Current.tenant_id,
        provider: context.provider,
        provider_event_id: context.provider_event_id
      )
    end

    def reconcile_webhook!(context)
      Integrations::Escrow::ReconcileWebhookEvent.new(
        tenant_id: Current.tenant_id,
        provider: context.provider,
        payload: context.payload,
        provider_event_id: context.provider_event_id,
        request_id: request.request_id,
        request_ip: request.remote_ip,
        user_agent: request.user_agent,
        endpoint_path: request.path,
        http_method: request.method
      ).call
    end

    def create_processed_receipt!(context:, result:)
      ProviderWebhookReceipt.create!(
        tenant_id: Current.tenant_id,
        provider: context.provider,
        provider_event_id: context.provider_event_id,
        event_type: context.event_type,
        signature: context.signature,
        payload_sha256: context.payload_sha256,
        payload: context.payload,
        request_headers: persisted_request_headers,
        status: result.status,
        processed_at: Time.current
      )
    end

    def capture_ignored_reconciliation_exception!(context:, outcome:)
      return unless outcome.result&.status == "IGNORED"

      capture_reconciliation_exception!(
        provider: context.provider,
        provider_event_id: context.provider_event_id,
        code: "escrow_webhook_resource_not_found",
        message: "Webhook payload did not match any escrow account or payout.",
        payload_sha256: context.payload_sha256,
        payload: context.payload,
        metadata: {
          "receipt_id" => outcome.receipt.id,
          "reconciliation_result" => outcome.result.metadata
        }
      )
    end

    def render_replayed_webhook(context:, receipt:)
      create_action_log!(
        action_type: "ESCROW_WEBHOOK_REPLAYED",
        success: true,
        target_type: "ProviderWebhookReceipt",
        target_id: receipt.id,
        metadata: {
          "provider" => context.provider,
          "provider_event_id" => context.provider_event_id,
          "receipt_status" => receipt.status
        }
      )

      render_replayed_payload(
        provider: context.provider,
        provider_event_id: context.provider_event_id,
        receipt_id: receipt.id
      )
    end

    def render_processed_webhook(context:, outcome:)
      create_action_log!(
        action_type: "ESCROW_WEBHOOK_RECEIVED",
        success: true,
        target_type: "ProviderWebhookReceipt",
        target_id: outcome.receipt.id,
        metadata: {
          "provider" => context.provider,
          "provider_event_id" => context.provider_event_id,
          "receipt_status" => outcome.receipt.status,
          "reconciliation_target_type" => outcome.result.target_type,
          "reconciliation_target_id" => outcome.result.target_id
        }
      )

      render json: {
        data: {
          status: outcome.result.status.downcase,
          provider: context.provider,
          provider_event_id: context.provider_event_id,
          receipt_id: outcome.receipt.id,
          reconciliation: {
            target_type: outcome.result.target_type,
            target_id: outcome.result.target_id
          }
        }
      }, status: :accepted
    end

    def handle_integration_error(error:, context:)
      create_failed_receipt!(context:, error:)

      capture_reconciliation_exception!(
        provider: context&.provider,
        provider_event_id: context&.provider_event_id,
        code: error.code,
        message: error.message,
        payload_sha256: context&.payload_sha256,
        payload: context&.payload || {},
        metadata: {
          "exception_class" => error.class.name
        }
      )

      create_action_log!(
        action_type: "ESCROW_WEBHOOK_FAILED",
        success: false,
        metadata: {
          "provider" => context&.provider,
          "provider_event_id" => context&.provider_event_id,
          "error_code" => error.code,
          "error_message" => error.message
        }
      )

      render_unprocessable(
        code: error.code,
        message: error.message
      )
    end

    def handle_record_not_unique(context:)
      if context.nil? || context.provider.blank? || context.provider_event_id.blank? || context.payload_sha256.blank?
        render_conflict(
          code: "webhook_idempotency_conflict",
          message: "Webhook event id conflict."
        )
        return
      end

      existing = ProviderWebhookReceipt.find_by(
        tenant_id: Current.tenant_id,
        provider: context.provider,
        provider_event_id: context.provider_event_id
      )
      if existing.nil?
        render_conflict(
          code: "webhook_idempotency_conflict",
          message: "Webhook event id conflict."
        )
        return
      end

      ensure_matching_payload!(existing:, payload_sha256: context.payload_sha256)
      render_replayed_payload(
        provider: context.provider,
        provider_event_id: context.provider_event_id,
        receipt_id: existing.id
      )
    end

    def render_replayed_payload(provider:, provider_event_id:, receipt_id:)
      render json: {
        data: {
          status: "replayed",
          provider: provider,
          provider_event_id: provider_event_id,
          receipt_id: receipt_id
        }
      }, status: :ok
    end

    def resolved_tenant_id
      @resolved_tenant_id ||= resolve_tenant_id_from_slug(params[:tenant_slug])
    end

    def resolved_actor_id
      nil
    end

    def resolved_role
      "webhook"
    end

    def parse_payload!(raw_body)
      parsed = JSON.parse(raw_body)
      return parsed if parsed.is_a?(Hash)

      raise BadRequestError.new(
        code: "webhook_payload_invalid",
        message: "Webhook payload must be a JSON object."
      )
    end

    def authenticate_signature!(provider:, raw_body:)
      Integrations::Escrow::Webhooks::AuthenticateRequest.new.call(
        provider: provider,
        request: request,
        raw_body: raw_body
      )
    end

    def resolve_provider_event_id(payload:, payload_sha256:)
      header_value = EVENT_ID_HEADER_CANDIDATES.lazy.map { |name| request.headers[name].to_s.strip.presence }.find(&:present?)
      payload_value = [
        payload["event_id"],
        payload["eventId"],
        payload["id"],
        payload["request_control_key"],
        payload["external_reference"],
        payload.dig("pix_transfer", "request_control_key")
      ].lazy.map { |value| value.to_s.strip.presence }.find(&:present?)

      if payload_value.present? && header_value.present? && payload_value != header_value
        raise BadRequestError.new(
          code: "webhook_event_id_mismatch",
          message: "Webhook event id mismatch between payload and headers."
        )
      end

      payload_value || payload_sha256
    end

    def ensure_matching_payload!(existing:, payload_sha256:)
      return if existing.payload_sha256 == payload_sha256

      raise ConflictError.new(
        code: "webhook_event_reused_with_different_payload",
        message: "Webhook event id was already used with a different payload."
      )
    end

    def create_failed_receipt!(context:, error:)
      return if context.nil?
      return if context.provider.blank? || context.provider_event_id.blank? || context.payload_sha256.blank?

      ProviderWebhookReceipt.create!(
        tenant_id: Current.tenant_id,
        provider: context.provider,
        provider_event_id: context.provider_event_id,
        event_type: context.event_type,
        signature: context.signature,
        payload_sha256: context.payload_sha256,
        payload: context.payload,
        request_headers: persisted_request_headers,
        status: "FAILED",
        error_code: error.code,
        error_message: error.message.to_s.truncate(500),
        processed_at: Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    rescue ActiveRecord::RecordInvalid
      nil
    end

    def persisted_request_headers
      {
        "x_webhook_id" => request.headers["X-Webhook-Id"].to_s,
        "x_request_id" => request.headers["X-Request-Id"].to_s,
        "x_qitech_signature" => request.headers["X-QITECH-Signature"].to_s,
        "x_starkbank_signature" => request.headers["X-STARKBANK-Signature"].to_s,
        "authorization_present" => request.authorization.present?,
        "content_type" => request.content_type.to_s
      }
    end

    def capture_reconciliation_exception!(
      provider:,
      provider_event_id:,
      code:,
      message:,
      payload_sha256:,
      payload:,
      metadata: {}
    )
      return if Current.tenant_id.blank?
      return if provider.blank? || provider_event_id.blank? || code.blank?

      ReconciliationException.capture!(
        tenant_id: Current.tenant_id,
        source: "ESCROW_WEBHOOK",
        provider: provider,
        external_event_id: provider_event_id,
        code: code,
        message: message,
        payload_sha256: payload_sha256,
        payload: payload,
        metadata: metadata
      )
    rescue ActiveRecord::RecordInvalid => error
      Rails.logger.error(
        "escrow_webhook_reconciliation_exception_invalid " \
        "error_message=#{error.message} request_id=#{request.request_id}"
      )
    rescue ActiveRecord::RecordNotUnique
      # Concurrent requests can race to capture the same exception signature.
      nil
    end

    def create_action_log!(action_type:, success:, target_type: nil, target_id: nil, metadata: {})
      return if Current.tenant_id.blank?

      ActionIpLog.create!(
        tenant_id: Current.tenant_id,
        action_type: action_type,
        ip_address: request.remote_ip.presence || "0.0.0.0",
        user_agent: request.user_agent,
        request_id: request.request_id,
        endpoint_path: request.path,
        http_method: request.method,
        channel: "WEBHOOK",
        target_type: target_type,
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: metadata
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      Rails.logger.error(
        "escrow_webhook_action_log_write_error " \
        "error_class=#{error.class.name} error_message=#{error.message} request_id=#{request.request_id}"
      )
    end

    def render_authentication_error(error)
      status = error.code == "webhook_auth_not_configured" ? :service_unavailable : :unauthorized
      render json: {
        error: {
          code: error.code,
          message: error.message,
          request_id: request.request_id
        }
      }, status: status
    end

    def render_invalid_json(_error)
      render_bad_request(code: "webhook_payload_invalid_json", message: "Webhook payload must be valid JSON.")
    end

    def render_webhook_error(error)
      if error.is_a?(ConflictError)
        render_conflict(code: error.code, message: error.message)
      else
        render_bad_request(code: error.code, message: error.message)
      end
    end

    def render_context_unavailable
      render json: {
        error: {
          code: "request_context_unavailable",
          message: "Request context could not be established.",
          request_id: request.request_id
        }
      }, status: :service_unavailable
    end

    def render_bad_request(code:, message:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: :bad_request
    end

    def render_unprocessable(code:, message:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: :unprocessable_entity
    end

    def render_conflict(code:, message:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: :conflict
    end

    def render_not_found(code:, message:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: :not_found
    end
  end
end
