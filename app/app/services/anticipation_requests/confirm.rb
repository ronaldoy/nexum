require "digest"

module AnticipationRequests
  class Confirm
    CONFIRMATION_PURPOSE = "ANTICIPATION_CONFIRMATION".freeze
    TARGET_TYPE = "AnticipationRequest".freeze
    PAYLOAD_HASH_METADATA_KEY = "_confirmation_payload_hash".freeze
    FIDC_FUNDING_OUTBOX_EVENT_TYPE = "ANTICIPATION_FIDC_FUNDING_REQUESTED".freeze
    FIDC_FUNDING_OUTBOX_IDEMPOTENCY_SUFFIX = "fidc_funding_request".freeze
    CONFIRMATION_CHANNELS = %w[EMAIL WHATSAPP].freeze
    RISK_BLOCKED_PUBLIC_MESSAGE = "Anticipation request blocked by risk policy.".freeze
    RISK_REVIEW_PUBLIC_MESSAGE = "Anticipation request requires manual review.".freeze
    REVIEW_PENDING_STATUS = "PENDING_REVIEW".freeze
    REQUESTED_STATUS = "REQUESTED".freeze

    Result = Struct.new(:anticipation_request, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end

    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    class IdempotencyConflict < ValidationError; end

    def initialize(
      tenant_id:,
      actor_role:,
      request_id:,
      idempotency_key:,
      request_ip:,
      user_agent:,
      endpoint_path:,
      http_method:
    )
      @tenant_id = tenant_id
      @actor_role = actor_role
      @request_id = request_id
      @idempotency_key = idempotency_key
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(anticipation_request_id:, email_code:, whatsapp_code:)
      payload_hash = confirmation_payload_hash(email_code:, whatsapp_code:)
      anticipation_request = nil

      ActiveRecord::Base.transaction do
        anticipation_request = find_anticipation_request!(anticipation_request_id)
        process_confirmation(
          anticipation_request: anticipation_request,
          payload_hash: payload_hash,
          email_code: email_code,
          whatsapp_code: whatsapp_code
        )
      end
    rescue ValidationError => error
      create_failure_log(error:, anticipation_request_id:, actor_party_id: anticipation_request&.requester_party_id)
      raise
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error:, anticipation_request_id:, actor_party_id: anticipation_request&.requester_party_id)
      raise
    end

    private

    def find_anticipation_request!(anticipation_request_id)
      AnticipationRequest.where(tenant_id: @tenant_id).lock.find(anticipation_request_id)
    end

    def process_confirmation(anticipation_request:, payload_hash:, email_code:, whatsapp_code:)
      return confirm_replay(anticipation_request:, payload_hash:) if anticipation_request.status == "APPROVED"

      validate_confirmable_status!(anticipation_request)
      confirm_requested_anticipation(anticipation_request:, payload_hash:, email_code:, whatsapp_code:)
    end

    def confirm_replay(anticipation_request:, payload_hash:)
      ensure_replay_compatibility!(anticipation_request:, payload_hash:)
      create_action_log!(
        action_type: "ANTICIPATION_CONFIRM_REPLAYED",
        success: true,
        requester_party_id: anticipation_request.requester_party_id,
        target_id: anticipation_request.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )
      Result.new(anticipation_request:, replayed: true)
    end

    def validate_confirmable_status!(anticipation_request)
      return if anticipation_request.status == REQUESTED_STATUS

      raise ValidationError.new(
        code: "anticipation_status_not_confirmable",
        message: "Only REQUESTED anticipation requests can be confirmed."
      )
    end

    def confirm_requested_anticipation(anticipation_request:, payload_hash:, email_code:, whatsapp_code:)
      risk_result = enforce_risk_policy!(anticipation_request)
      return Result.new(anticipation_request:, replayed: false) if risk_result == :pending_review

      email_challenge, whatsapp_challenge = load_confirmation_challenges!(anticipation_request)
      verify_confirmation_codes!(
        email_challenge: email_challenge,
        whatsapp_challenge: whatsapp_challenge,
        email_code: email_code,
        whatsapp_code: whatsapp_code
      )

      confirmed_at = Time.current
      transition_to_approved!(
        anticipation_request: anticipation_request,
        confirmed_at: confirmed_at,
        payload_hash: payload_hash
      )

      create_receivable_event!(
        anticipation_request: anticipation_request,
        email_challenge: email_challenge,
        whatsapp_challenge: whatsapp_challenge,
        occurred_at: confirmed_at
      )
      create_fidc_funding_outbox_event!(anticipation_request: anticipation_request)
      log_confirmation_success!(anticipation_request: anticipation_request)

      Result.new(anticipation_request:, replayed: false)
    end

    def enforce_risk_policy!(anticipation_request)
      decision = risk_evaluator.evaluate!(
        receivable: anticipation_request.receivable,
        receivable_allocation: anticipation_request.receivable_allocation,
        requester_party: anticipation_request.requester_party,
        requested_amount: anticipation_request.requested_amount.to_d,
        net_amount: anticipation_request.net_amount.to_d,
        stage: :confirm
      )
      create_risk_decision_record!(anticipation_request: anticipation_request, decision: decision)
      return :allow if decision.allowed?
      if decision.action == "REVIEW"
        move_to_pending_review!(anticipation_request: anticipation_request, decision: decision)
        return :pending_review
      end

      raise_validation_error!(decision.code, risk_public_message(decision))
    end

    def create_risk_decision_record!(anticipation_request:, decision:)
      AnticipationRiskDecision.create!(
        tenant_id: @tenant_id,
        anticipation_request: anticipation_request,
        receivable: anticipation_request.receivable,
        receivable_allocation: anticipation_request.receivable_allocation,
        requester_party: anticipation_request.requester_party,
        scope_party_id: decision.scope_party_id,
        trigger_rule_id: decision.rule&.id,
        scope_type: decision.scope_type,
        stage: "CONFIRM",
        decision_action: decision.action,
        decision_code: decision.code,
        decision_metric: decision.metric,
        requested_amount: anticipation_request.requested_amount.to_d,
        net_amount: anticipation_request.net_amount.to_d,
        request_id: @request_id,
        idempotency_key: @idempotency_key,
        evaluated_at: Time.current,
        details: normalized_metadata(
          (decision.details || {}).merge(
            "rule_snapshot" => risk_rule_snapshot(decision.rule)
          )
        )
      )
    end

    def move_to_pending_review!(anticipation_request:, decision:)
      reviewed_at = Time.current
      anticipation_request.transition_status!(
        REVIEW_PENDING_STATUS,
        metadata: {
          "review_pending_at" => reviewed_at.utc.iso8601(6),
          "review_pending_reason_code" => decision.code,
          "review_pending_idempotency_key" => @idempotency_key
        }
      )

      create_review_pending_receivable_event!(
        anticipation_request: anticipation_request,
        decision: decision,
        occurred_at: reviewed_at
      )

      create_action_log!(
        action_type: "ANTICIPATION_REVIEW_PENDING",
        success: true,
        requester_party_id: anticipation_request.requester_party_id,
        target_id: anticipation_request.id,
        metadata: {
          replayed: false,
          idempotency_key: @idempotency_key,
          decision_action: decision.action,
          decision_code: decision.code
        }
      )
    end

    def create_review_pending_receivable_event!(anticipation_request:, decision:, occurred_at:)
      receivable = anticipation_request.receivable
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      event_type = "ANTICIPATION_REVIEW_PENDING"

      payload = {
        anticipation_request_id: anticipation_request.id,
        idempotency_key: @idempotency_key,
        decision_code: decision.code,
        decision_metric: decision.metric
      }.compact

      event_hash = Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable.id,
          sequence: sequence,
          event_type: event_type,
          occurred_at: occurred_at.utc.iso8601(6),
          request_id: @request_id,
          prev_hash: prev_hash,
          payload: payload
        )
      )

      ReceivableEvent.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        sequence: sequence,
        event_type: event_type,
        actor_party_id: anticipation_request.requester_party_id,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def load_confirmation_challenges!(anticipation_request)
      [
        load_challenge!(anticipation_request: anticipation_request, channel: "EMAIL"),
        load_challenge!(anticipation_request: anticipation_request, channel: "WHATSAPP")
      ]
    end

    def verify_confirmation_codes!(email_challenge:, whatsapp_challenge:, email_code:, whatsapp_code:)
      verify_challenge!(challenge: email_challenge, code: email_code, invalid_code: "invalid_email_code")
      verify_challenge!(challenge: whatsapp_challenge, code: whatsapp_code, invalid_code: "invalid_whatsapp_code")
    end

    def transition_to_approved!(anticipation_request:, confirmed_at:, payload_hash:)
      anticipation_request.transition_status!(
        "APPROVED",
        metadata: {
          "confirmed_at" => confirmed_at.utc.iso8601(6),
          "confirmation_channels" => CONFIRMATION_CHANNELS,
          "confirmation_idempotency_key" => @idempotency_key,
          PAYLOAD_HASH_METADATA_KEY => payload_hash
        }
      )
    end

    def log_confirmation_success!(anticipation_request:)
      create_action_log!(
        action_type: "ANTICIPATION_CONFIRMED",
        success: true,
        requester_party_id: anticipation_request.requester_party_id,
        target_id: anticipation_request.id,
        metadata: {
          replayed: false,
          idempotency_key: @idempotency_key,
          confirmation_channels: CONFIRMATION_CHANNELS
        }
      )
    end

    def load_challenge!(anticipation_request:, channel:)
      challenge = AuthChallenge.where(
        tenant_id: @tenant_id,
        actor_party_id: anticipation_request.requester_party_id,
        purpose: CONFIRMATION_PURPOSE,
        delivery_channel: channel,
        target_type: TARGET_TYPE,
        target_id: anticipation_request.id
      ).where(status: %w[PENDING VERIFIED]).order(created_at: :desc).lock(true).first

      return challenge if challenge

      raise_validation_error!(
        "missing_#{channel.downcase}_challenge",
        "Missing #{channel.downcase} challenge."
      )
    end

    def verify_challenge!(challenge:, code:, invalid_code:)
      return if challenge.status == "VERIFIED"

      ensure_confirmation_code_present!(code: code, invalid_code: invalid_code)
      expire_challenge_if_needed!(challenge)
      process_challenge_attempt!(challenge: challenge, code: code, invalid_code: invalid_code)
    end

    def ensure_confirmation_code_present!(code:, invalid_code:)
      return if code.to_s.strip.present?

      raise_validation_error!(invalid_code, "Confirmation code is required.")
    end

    def expire_challenge_if_needed!(challenge)
      return if challenge.expires_at > Time.current

      challenge.update!(status: "EXPIRED")
      raise_validation_error!("challenge_expired", "Confirmation challenge is expired.")
    end

    def process_challenge_attempt!(challenge:, code:, invalid_code:)
      attempts = challenge.attempts + 1
      return mark_challenge_verified!(challenge: challenge, attempts: attempts) if valid_confirmation_code?(challenge: challenge, code: code)

      register_invalid_challenge_attempt!(challenge: challenge, attempts: attempts, invalid_code: invalid_code)
    end

    def valid_confirmation_code?(challenge:, code:)
      AuthChallenge.valid_code?(raw_code: code, stored_digest: challenge.code_digest)
    end

    def mark_challenge_verified!(challenge:, attempts:)
      challenge.update!(status: "VERIFIED", consumed_at: Time.current, attempts: attempts)
    end

    def register_invalid_challenge_attempt!(challenge:, attempts:, invalid_code:)
      updates = { attempts: attempts }
      if attempts >= challenge.max_attempts
        updates[:status] = "CANCELLED"
        challenge.update!(updates)
        raise_validation_error!("challenge_attempts_exceeded", "Confirmation challenge exceeded maximum attempts.")
      end

      challenge.update!(updates)
      raise_validation_error!(invalid_code, "Confirmation code is invalid.")
    end

    def ensure_replay_compatibility!(anticipation_request:, payload_hash:)
      stored_hash = anticipation_request.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.blank? || stored_hash == payload_hash

      raise IdempotencyConflict.new(
        code: "idempotency_key_reused_with_different_payload",
        message: "Idempotency-Key was already used with a different confirmation payload."
      )
    end

    def create_receivable_event!(anticipation_request:, email_challenge:, whatsapp_challenge:, occurred_at:)
      receivable = anticipation_request.receivable
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      event_type = "ANTICIPATION_CONFIRMED"

      payload = {
        anticipation_request_id: anticipation_request.id,
        idempotency_key: @idempotency_key,
        confirmation_channels: CONFIRMATION_CHANNELS
      }.merge(challenge_reference_payload(email_challenge:, whatsapp_challenge:))

      event_hash = Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable.id,
          sequence: sequence,
          event_type: event_type,
          occurred_at: occurred_at.utc.iso8601(6),
          request_id: @request_id,
          prev_hash: prev_hash,
          payload: payload
        )
      )

      ReceivableEvent.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        sequence: sequence,
        event_type: event_type,
        actor_party_id: anticipation_request.requester_party_id,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def create_action_log!(action_type:, success:, requester_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: action_type,
          actor_party_id: requester_party_id,
          target_id: target_id,
          success: success
        ),
        metadata: normalized_metadata(metadata)
      )
    end

    def create_fidc_funding_outbox_event!(anticipation_request:)
      provider = Integrations::Fidc::ProviderConfig.default_provider(tenant_id: @tenant_id)
      receivable = anticipation_request.receivable
      funding_amount = decimal_as_string(anticipation_request.net_amount)
      funding_idempotency_key = "#{anticipation_request.id}:#{FIDC_FUNDING_OUTBOX_IDEMPOTENCY_SUFFIX}"
      receivable_origin = receivable_origin_payload(receivable)
      payload_hash = fidc_funding_payload_hash(
        anticipation_request: anticipation_request,
        provider: provider,
        amount: funding_amount,
        receivable_origin: receivable_origin
      )
      outbox_payload = build_fidc_funding_outbox_payload(
        anticipation_request: anticipation_request,
        provider: provider,
        funding_amount: funding_amount,
        funding_idempotency_key: funding_idempotency_key,
        payload_hash: payload_hash,
        receivable_origin: receivable_origin
      )

      OutboxEvent.create!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: anticipation_request.id,
        event_type: FIDC_FUNDING_OUTBOX_EVENT_TYPE,
        status: "PENDING",
        idempotency_key: funding_idempotency_key,
        payload: outbox_payload
      )
    rescue ActiveRecord::RecordNotUnique
      assert_outbox_payload_hash_matches!(
        idempotency_key: funding_idempotency_key,
        payload_hash: payload_hash,
        code: "fidc_funding_idempotency_conflict",
        message: "FIDC funding idempotency key was already used with a different payload."
      )
    end

    def build_fidc_funding_outbox_payload(anticipation_request:, provider:, funding_amount:, funding_idempotency_key:, payload_hash:, receivable_origin:)
      {
        "payload_hash" => payload_hash,
        "anticipation_request_id" => anticipation_request.id,
        "receivable_id" => anticipation_request.receivable_id,
        "receivable_allocation_id" => anticipation_request.receivable_allocation_id,
        "requester_party_id" => anticipation_request.requester_party_id,
        "amount" => funding_amount,
        "currency" => "BRL",
        "provider" => provider,
        "operation_kind" => "FUNDING_REQUEST",
        "operation_idempotency_key" => funding_idempotency_key,
        "provider_request_control_key" => funding_idempotency_key,
        "requested_amount" => decimal_as_string(anticipation_request.requested_amount),
        "discount_amount" => decimal_as_string(anticipation_request.discount_amount),
        "net_amount" => funding_amount,
        "receivable_origin" => receivable_origin
      }
    end

    def assert_outbox_payload_hash_matches!(idempotency_key:, payload_hash:, code:, message:)
      existing = OutboxEvent.find_by!(
        tenant_id: @tenant_id,
        idempotency_key: idempotency_key
      )
      stored_hash = existing.payload&.dig("payload_hash").to_s
      return if stored_hash.blank? || stored_hash == payload_hash

      raise IdempotencyConflict.new(code: code, message: message)
    end

    def create_failure_log(error:, anticipation_request_id:, actor_party_id:)
      metadata = {
        replayed: false,
        idempotency_key: @idempotency_key,
        error_class: error.class.name,
        error_code: error.respond_to?(:code) ? error.code : "not_found",
        error_message: error.message
      }

      ActionIpLog.create!(
        **base_action_log_attributes(
          action_type: "ANTICIPATION_CONFIRM_FAILED",
          actor_party_id: actor_party_id,
          target_id: anticipation_request_id,
          success: false
        ),
        metadata: metadata
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
      Rails.logger.error(
        "anticipation_confirm_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
      nil
    end

    def base_action_log_attributes(action_type:, actor_party_id:, target_id:, success:)
      {
        tenant_id: @tenant_id,
        actor_party_id: actor_party_id,
        action_type: action_type,
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: TARGET_TYPE,
        target_id: target_id,
        success: success,
        occurred_at: Time.current
      }
    end

    def confirmation_payload_hash(email_code:, whatsapp_code:)
      Digest::SHA256.hexdigest(
        canonical_json(
          email_code: email_code.to_s.strip,
          whatsapp_code: whatsapp_code.to_s.strip
        )
      )
    end

    def canonical_json(value)
      CanonicalJson.encode(value)
    end

    def decimal_as_string(value)
      value.to_d.to_s("F")
    end

    def fidc_funding_payload_hash(anticipation_request:, provider:, amount:, receivable_origin:)
      Digest::SHA256.hexdigest(
        canonical_json(
          anticipation_request_id: anticipation_request.id,
          receivable_id: anticipation_request.receivable_id,
          receivable_allocation_id: anticipation_request.receivable_allocation_id,
          requester_party_id: anticipation_request.requester_party_id,
          provider: provider,
          amount: amount,
          currency: "BRL",
          operation_kind: "FUNDING_REQUEST",
          receivable_origin: receivable_origin
        )
      )
    end

    def receivable_origin_payload(receivable)
      ownership = active_hospital_ownership(hospital_party_id: receivable.debtor_party_id)

      {
        "receivable_id" => receivable.id,
        "external_reference" => receivable.external_reference,
        "hospital_party_id" => receivable.debtor_party_id,
        "hospital_legal_name" => receivable.debtor_party.legal_name,
        "hospital_document_number" => receivable.debtor_party.document_number,
        "organization_party_id" => ownership&.organization_party_id,
        "organization_legal_name" => ownership&.organization_party&.legal_name,
        "organization_document_number" => ownership&.organization_party&.document_number
      }.compact
    end

    def active_hospital_ownership(hospital_party_id:)
      HospitalOwnership
        .where(tenant_id: @tenant_id, hospital_party_id: hospital_party_id, active: true)
        .includes(:organization_party)
        .first
    end

    def challenge_reference_payload(email_challenge:, whatsapp_challenge:)
      {
        email_challenge_id: email_challenge.id,
        whatsapp_challenge_id: whatsapp_challenge.id
      }
    end

    def normalized_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalized_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalized_metadata(value)
        end
      when Array
        raw_metadata.map { |entry| normalized_metadata(entry) }
      else
        raw_metadata
      end
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end

    def risk_public_message(decision)
      return RISK_REVIEW_PUBLIC_MESSAGE if decision.action == "REVIEW"

      RISK_BLOCKED_PUBLIC_MESSAGE
    end

    def risk_rule_snapshot(rule)
      return {} if rule.blank?

      {
        id: rule.id,
        scope_type: rule.scope_type,
        scope_party_id: rule.scope_party_id,
        decision: rule.decision,
        priority: rule.priority,
        active: rule.active,
        max_single_request_amount: decimal_or_nil(rule.max_single_request_amount),
        max_daily_requested_amount: decimal_or_nil(rule.max_daily_requested_amount),
        max_outstanding_exposure_amount: decimal_or_nil(rule.max_outstanding_exposure_amount),
        max_open_requests_count: rule.max_open_requests_count,
        max_requests_per_minute: rule.max_requests_per_minute,
        max_requests_per_hour: rule.max_requests_per_hour,
        pair_spike_multiplier: decimal_or_nil(rule.pair_spike_multiplier),
        pair_spike_min_daily_amount: decimal_or_nil(rule.pair_spike_min_daily_amount),
        near_limit_attempts_window_minutes: rule.near_limit_attempts_window_minutes,
        near_limit_attempts_max_count: rule.near_limit_attempts_max_count,
        near_limit_ratio: decimal_or_nil(rule.near_limit_ratio),
        effective_from: rule.effective_from&.utc&.iso8601(6),
        effective_until: rule.effective_until&.utc&.iso8601(6)
      }.compact
    end

    def decimal_or_nil(value)
      return nil if value.blank?

      decimal_as_string(value)
    end

    def risk_evaluator
      @risk_evaluator ||= AnticipationRisk::Evaluator.new(tenant_id: @tenant_id)
    end
  end
end
