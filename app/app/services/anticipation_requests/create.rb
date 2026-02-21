require "digest"
require "json"

module AnticipationRequests
  class Create
    ACTIVE_STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED].freeze
    ELIGIBLE_RECEIVABLE_STATUSES = %w[PERFORMED ANTICIPATION_REQUESTED].freeze
    CURRENCY_SCALE = 2
    RATE_SCALE = 8
    PAYLOAD_HASH_METADATA_KEY = "_idempotency_payload_hash".freeze

    Intent = Struct.new(
      :receivable_id,
      :receivable_allocation_id,
      :requester_party_id,
      :requested_amount,
      :discount_rate,
      :channel,
      :metadata,
      keyword_init: true
    )

    Financials = Struct.new(:requested_at, :discount_amount, :net_amount, keyword_init: true)

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

    def call(raw_payload, default_requester_party_id:)
      intent = normalize_intent(raw_payload, default_requester_party_id:)
      intent_hash = idempotency_payload_hash(intent)

      ActiveRecord::Base.transaction { create_or_replay_request(intent: intent, intent_hash: intent_hash) }
    rescue ActiveRecord::RecordNotUnique
      replay_existing_for_race_condition(intent:, intent_hash:)
    end

    private

    def create_or_replay_request(intent:, intent_hash:)
      existing = AnticipationRequest.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return build_replay_result(existing:, intent:, intent_hash:) if existing

      create_new_request(intent:, intent_hash:)
    end

    def create_new_request(intent:, intent_hash:)
      receivable, allocation, requester_party = load_request_context!(intent)
      financials = calculate_financials(intent)
      anticipation_request = create_anticipation_request_record!(
        intent: intent,
        intent_hash: intent_hash,
        receivable: receivable,
        allocation: allocation,
        requester_party: requester_party,
        financials: financials
      )

      mark_receivable_as_anticipated!(receivable)
      create_receivable_event!(
        receivable: receivable,
        requester_party: requester_party,
        anticipation_request: anticipation_request,
        occurred_at: financials.requested_at
      )
      create_action_log!(
        action_type: "ANTICIPATION_REQUEST_CREATED",
        success: true,
        requester_party_id: requester_party.id,
        target_id: anticipation_request.id,
        metadata: { replayed: false, idempotency_key: @idempotency_key }
      )

      Result.new(anticipation_request: anticipation_request, replayed: false)
    end

    def build_replay_result(existing:, intent:, intent_hash:)
      ensure_matching_idempotency!(existing:, intent:, intent_hash:)
      create_action_log!(
        action_type: "ANTICIPATION_REQUEST_REPLAYED",
        success: true,
        requester_party_id: existing.requester_party_id,
        target_id: existing.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key }
      )
      Result.new(anticipation_request: existing, replayed: true)
    end

    def load_request_context!(intent)
      receivable = Receivable.where(tenant_id: @tenant_id).lock.find(intent.receivable_id)
      ensure_receivable_eligible!(receivable)

      allocation = resolve_allocation(receivable:, receivable_allocation_id: intent.receivable_allocation_id)
      requester_party = resolve_requester_party!(requester_party_id: intent.requester_party_id)
      ensure_requester_authorized!(receivable:, allocation:, requester_party:)
      ensure_requested_amount_available!(receivable:, allocation:, requested_amount: intent.requested_amount)

      [ receivable, allocation, requester_party ]
    end

    def calculate_financials(intent)
      requested_at = Time.current
      discount_amount = round_currency(intent.requested_amount * intent.discount_rate)
      net_amount = round_currency(intent.requested_amount - discount_amount)
      ensure_positive_net_amount!(net_amount)

      Financials.new(
        requested_at: requested_at,
        discount_amount: discount_amount,
        net_amount: net_amount
      )
    end

    def create_anticipation_request_record!(intent:, intent_hash:, receivable:, allocation:, requester_party:, financials:)
      AnticipationRequest.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: requester_party,
        idempotency_key: @idempotency_key,
        requested_amount: intent.requested_amount,
        discount_rate: intent.discount_rate,
        discount_amount: financials.discount_amount,
        net_amount: financials.net_amount,
        status: "REQUESTED",
        channel: intent.channel,
        requested_at: financials.requested_at,
        settlement_target_date: BusinessCalendar.next_business_day(from: financials.requested_at),
        metadata: intent.metadata.merge(PAYLOAD_HASH_METADATA_KEY => intent_hash)
      )
    end

    def mark_receivable_as_anticipated!(receivable)
      return if receivable.status == "ANTICIPATION_REQUESTED"

      receivable.update!(status: "ANTICIPATION_REQUESTED")
    end

    def normalize_intent(raw_payload, default_requester_party_id:)
      payload = raw_payload.to_h.deep_symbolize_keys
      requester_party_id = payload[:requester_party_id].presence || default_requester_party_id
      raise_validation_error!("requester_party_required", "Requester party is required.") if requester_party_id.blank?

      channel = payload[:channel].presence || "API"
      normalized_channel = channel.to_s.upcase
      unless AnticipationRequest::CHANNELS.include?(normalized_channel)
        raise_validation_error!("invalid_channel", "Channel is invalid.")
      end

      metadata = normalize_metadata(payload[:metadata] || {})
      unless metadata.is_a?(Hash)
        raise_validation_error!("invalid_metadata", "Metadata must be a JSON object.")
      end

      Intent.new(
        receivable_id: payload[:receivable_id].to_s,
        receivable_allocation_id: payload[:receivable_allocation_id].presence&.to_s,
        requester_party_id: requester_party_id.to_s,
        requested_amount: round_currency(parse_decimal(payload[:requested_amount], field: "requested_amount")),
        discount_rate: round_rate(parse_decimal(payload[:discount_rate], field: "discount_rate")),
        channel: normalized_channel,
        metadata:
      )
    end

    def parse_decimal(raw_value, field:)
      value = BigDecimal(raw_value.to_s)
      return value if value.finite?

      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    rescue ArgumentError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    end

    def round_currency(value)
      value.to_d.round(CURRENCY_SCALE, BigDecimal::ROUND_UP)
    end

    def round_rate(value)
      value.to_d.round(RATE_SCALE, BigDecimal::ROUND_UP)
    end

    def ensure_positive_net_amount!(net_amount)
      return if net_amount.positive?

      raise_validation_error!("non_positive_net_amount", "Net amount must be greater than zero.")
    end

    def ensure_receivable_eligible!(receivable)
      return if ELIGIBLE_RECEIVABLE_STATUSES.include?(receivable.status)

      raise_validation_error!("receivable_not_eligible", "Receivable is not eligible for anticipation.")
    end

    def resolve_allocation(receivable:, receivable_allocation_id:)
      return nil if receivable_allocation_id.blank?

      ReceivableAllocation.where(tenant_id: @tenant_id, receivable_id: receivable.id).find(receivable_allocation_id)
    end

    def resolve_requester_party!(requester_party_id:)
      Party.where(tenant_id: @tenant_id).find(requester_party_id)
    end

    def ensure_requester_authorized!(receivable:, allocation:, requester_party:)
      allowed_party_ids = allowed_requester_party_ids(receivable: receivable, allocation: allocation)

      return if allowed_party_ids.include?(requester_party.id)

      raise_validation_error!(
        "requester_not_authorized",
        "Requester party is not authorized for this receivable."
      )
    end

    def allowed_requester_party_ids(receivable:, allocation:)
      party_ids = [ receivable.creditor_party_id, receivable.beneficiary_party_id ]
      if allocation
        party_ids << allocation.allocated_party_id
        party_ids << allocation.physician_party_id
      end
      party_ids.compact.uniq
    end

    def ensure_requested_amount_available!(receivable:, allocation:, requested_amount:)
      if requested_amount <= 0
        raise_validation_error!("invalid_requested_amount", "requested_amount must be greater than zero.")
      end

      available_amount = available_amount_for_request(receivable: receivable, allocation: allocation)

      return if requested_amount <= available_amount

      raise_validation_error!(
        "requested_amount_exceeds_available",
        "Requested amount exceeds available amount for anticipation."
      )
    end

    def available_amount_for_request(receivable:, allocation:)
      base_amount = allocation ? allocation_available_amount(allocation) : receivable.gross_amount.to_d
      requested_total = active_requests_for(receivable: receivable, allocation: allocation).sum(:requested_amount).to_d
      round_currency(base_amount - requested_total)
    end

    def allocation_available_amount(allocation)
      splitter = ReceivableAllocations::CnpjSplit.new(tenant_id: @tenant_id)
      splitter.available_amount_for_anticipation(allocation)
    end

    def active_requests_for(receivable:, allocation:)
      scope = AnticipationRequest.where(
        tenant_id: @tenant_id,
        receivable_id: receivable.id,
        status: ACTIVE_STATUSES
      )
      return scope unless allocation

      scope.where(receivable_allocation_id: allocation.id)
    end

    def ensure_matching_idempotency!(existing:, intent:, intent_hash:)
      stored_hash = existing.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.present? && stored_hash == intent_hash
      return if stored_hash.blank? && fallback_idempotency_match?(existing:, intent:)

      raise IdempotencyConflict.new(
        code: "idempotency_key_reused_with_different_payload",
        message: "Idempotency-Key was already used with a different payload."
      )
    end

    def fallback_idempotency_match?(existing:, intent:)
      existing_metadata = normalize_metadata((existing.metadata || {}).except(PAYLOAD_HASH_METADATA_KEY))

      existing.receivable_id.to_s == intent.receivable_id &&
        existing.receivable_allocation_id.to_s == intent.receivable_allocation_id.to_s &&
        existing.requester_party_id.to_s == intent.requester_party_id &&
        existing.requested_amount.to_d == intent.requested_amount &&
        existing.discount_rate.to_d == intent.discount_rate &&
        existing.channel == intent.channel &&
        existing_metadata == intent.metadata
    end

    def replay_existing_for_race_condition(intent:, intent_hash:)
      existing = AnticipationRequest.find_by!(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      ensure_matching_idempotency!(existing:, intent:, intent_hash:)
      Result.new(anticipation_request: existing, replayed: true)
    end

    def create_receivable_event!(receivable:, requester_party:, anticipation_request:, occurred_at:)
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      payload = receivable_event_payload(anticipation_request)
      event_type = "ANTICIPATION_REQUESTED"

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
        actor_party: requester_party,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def receivable_event_payload(anticipation_request)
      {
        anticipation_request_id: anticipation_request.id,
        idempotency_key: @idempotency_key,
        requested_amount: decimal_as_string(anticipation_request.requested_amount),
        discount_rate: decimal_as_string(anticipation_request.discount_rate),
        discount_amount: decimal_as_string(anticipation_request.discount_amount),
        net_amount: decimal_as_string(anticipation_request.net_amount),
        settlement_target_date: anticipation_request.settlement_target_date&.iso8601,
        channel: anticipation_request.channel
      }
    end

    def create_action_log!(action_type:, success:, requester_party_id:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: requester_party_id,
        action_type: action_type,
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: "AnticipationRequest",
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: normalize_metadata(metadata)
      )
    end

    def idempotency_payload_hash(intent)
      payload = {
        receivable_id: intent.receivable_id,
        receivable_allocation_id: intent.receivable_allocation_id,
        requester_party_id: intent.requester_party_id,
        requested_amount: decimal_as_string(intent.requested_amount),
        discount_rate: decimal_as_string(intent.discount_rate),
        channel: intent.channel,
        metadata: intent.metadata
      }

      Digest::SHA256.hexdigest(canonical_json(payload))
    end

    def canonical_json(value)
      CanonicalJson.encode(value)
    end

    def decimal_as_string(value)
      value.to_d.to_s("F")
    end

    def normalize_metadata(raw_metadata)
      case raw_metadata
      when ActionController::Parameters
        normalize_metadata(raw_metadata.to_unsafe_h)
      when Hash
        raw_metadata.each_with_object({}) do |(key, value), output|
          output[key.to_s] = normalize_metadata(value)
        end
      when Array
        raw_metadata.map { |entry| normalize_metadata(entry) }
      else
        raw_metadata
      end
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
