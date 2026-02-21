require "digest"

module Receivables
  class Create
    TARGET_TYPE = "Receivable".freeze
    PAYLOAD_HASH_METADATA_KEY = "_create_payload_hash".freeze

    Result = Struct.new(:receivable, :allocation, :replayed, keyword_init: true) do
      def replayed?
        replayed
      end
    end
    CallInputs = Struct.new(:payload, :payload_hash, keyword_init: true)
    CreationContext = Struct.new(
      :receivable_kind,
      :debtor_party,
      :creditor_party,
      :beneficiary_party,
      :gross_amount,
      :performed_at,
      :due_at,
      :cutoff_at,
      keyword_init: true
    )

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
      @idempotency_key = idempotency_key.to_s.strip
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(raw_payload)
      raise_validation_error!("missing_idempotency_key", "Idempotency-Key is required.") if @idempotency_key.blank?

      inputs = build_call_inputs(raw_payload)
      ActiveRecord::Base.transaction { create_or_replay(inputs) }
    rescue ActiveRecord::RecordNotUnique
      replay_after_race(payload: inputs&.payload || normalize_payload(raw_payload), payload_hash: inputs&.payload_hash.to_s)
    rescue ActiveRecord::RecordInvalid => error
      raise ValidationError.new(code: "invalid_receivable_payload", message: error.record.errors.full_messages.to_sentence)
    end

    private

    def build_call_inputs(raw_payload)
      payload = normalize_payload(raw_payload)
      payload_hash = receivable_payload_hash(payload)
      CallInputs.new(payload:, payload_hash:)
    end

    def create_or_replay(inputs)
      existing = find_existing_receivable(inputs.payload)
      return build_replay_result(existing:, inputs:) if existing

      create_new_receivable(inputs)
    end

    def find_existing_receivable(payload)
      Receivable.where(tenant_id: @tenant_id, external_reference: payload.fetch(:external_reference)).lock.first
    end

    def build_replay_result(existing:, inputs:)
      allocation = existing.receivable_allocations.order(sequence: :asc).first
      ensure_matching_replay!(
        existing: existing,
        allocation: allocation,
        payload_hash: inputs.payload_hash,
        payload: inputs.payload
      )
      create_action_log!(
        action_type: "RECEIVABLE_CREATE_REPLAYED",
        success: true,
        target_id: existing.id,
        metadata: { replayed: true, idempotency_key: @idempotency_key, external_reference: existing.external_reference }
      )
      Result.new(receivable: existing, allocation: allocation, replayed: true)
    end

    def create_new_receivable(inputs)
      context = build_creation_context(inputs.payload)
      receivable = create_receivable_record!(payload: inputs.payload, payload_hash: inputs.payload_hash, context:)
      allocation = create_primary_allocation!(
        receivable: receivable,
        payload: inputs.payload,
        gross_amount: context.gross_amount
      )

      create_receivable_event!(
        receivable: receivable,
        allocation: allocation,
        occurred_at: context.performed_at
      )

      create_action_log!(
        action_type: "RECEIVABLE_CREATED",
        success: true,
        target_id: receivable.id,
        metadata: {
          replayed: false,
          idempotency_key: @idempotency_key,
          external_reference: receivable.external_reference,
          receivable_kind_code: context.receivable_kind.code
        }
      )

      Result.new(receivable: receivable, allocation: allocation, replayed: false)
    end

    def build_creation_context(payload)
      receivable_kind = ReceivableKind.where(tenant_id: @tenant_id, code: payload.fetch(:receivable_kind_code)).first
      raise_validation_error!("receivable_kind_not_found", "Receivable kind is invalid.") if receivable_kind.blank?

      parties = load_creation_parties(payload)
      validate_debtor_party!(parties.fetch(:debtor_party))

      gross_amount = round_money(parse_decimal(payload.fetch(:gross_amount), field: "gross_amount"))
      raise_validation_error!("invalid_gross_amount", "gross_amount must be greater than zero.") if gross_amount <= 0

      performed_at = parse_time(payload[:performed_at].presence || Time.current, field: "performed_at")
      due_at = parse_time(payload.fetch(:due_at), field: "due_at")
      cutoff_at = parse_time(
        payload[:cutoff_at].presence || BusinessCalendar.cutoff_at(performed_at.in_time_zone.to_date),
        field: "cutoff_at"
      )

      CreationContext.new(
        receivable_kind: receivable_kind,
        debtor_party: parties.fetch(:debtor_party),
        creditor_party: parties.fetch(:creditor_party),
        beneficiary_party: parties.fetch(:beneficiary_party),
        gross_amount: gross_amount,
        performed_at: performed_at,
        due_at: due_at,
        cutoff_at: cutoff_at
      )
    end

    def load_creation_parties(payload)
      {
        debtor_party: load_party!(payload.fetch(:debtor_party_id)),
        creditor_party: load_party!(payload.fetch(:creditor_party_id)),
        beneficiary_party: load_party!(payload.fetch(:beneficiary_party_id))
      }
    end

    def load_party!(party_id)
      Party.where(tenant_id: @tenant_id).find(party_id)
    end

    def validate_debtor_party!(debtor_party)
      return if debtor_party.kind == "HOSPITAL"

      raise_validation_error!("debtor_party_kind_invalid", "Debtor party must be a HOSPITAL.")
    end

    def create_receivable_record!(payload:, payload_hash:, context:)
      Receivable.create!(
        tenant_id: @tenant_id,
        receivable_kind: context.receivable_kind,
        debtor_party: context.debtor_party,
        creditor_party: context.creditor_party,
        beneficiary_party: context.beneficiary_party,
        external_reference: payload.fetch(:external_reference),
        gross_amount: context.gross_amount,
        currency: "BRL",
        status: "PERFORMED",
        performed_at: context.performed_at,
        due_at: context.due_at,
        cutoff_at: context.cutoff_at,
        metadata: build_receivable_metadata(raw_metadata: payload[:metadata], payload_hash: payload_hash)
      )
    end

    def build_receivable_metadata(raw_metadata:, payload_hash:)
      normalize_hash_metadata(raw_metadata).merge(
        PAYLOAD_HASH_METADATA_KEY => payload_hash,
        "idempotency_key" => @idempotency_key
      )
    end

    def normalize_payload(raw_payload)
      payload = raw_payload.to_h.symbolize_keys

      external_reference = required_string!(
        value: payload[:external_reference],
        code: "external_reference_required",
        message: "external_reference is required."
      )
      receivable_kind_code = required_string!(
        value: payload[:receivable_kind_code],
        code: "receivable_kind_code_required",
        message: "receivable_kind_code is required."
      )
      debtor_party_id = required_string!(
        value: payload[:debtor_party_id],
        code: "debtor_party_required",
        message: "debtor_party_id is required."
      )
      creditor_party_id = required_string!(
        value: payload[:creditor_party_id],
        code: "creditor_party_required",
        message: "creditor_party_id is required."
      )
      beneficiary_party_id = required_string!(
        value: payload[:beneficiary_party_id],
        code: "beneficiary_party_required",
        message: "beneficiary_party_id is required."
      )
      currency = normalize_currency(payload[:currency])

      raise_validation_error!("invalid_currency", "currency must be BRL.") if currency != "BRL"

      allocation_payload = normalize_metadata(payload[:allocation])
      allocation_payload = {} unless allocation_payload.is_a?(Hash)
      {
        external_reference: external_reference,
        receivable_kind_code: receivable_kind_code,
        debtor_party_id: debtor_party_id,
        creditor_party_id: creditor_party_id,
        beneficiary_party_id: beneficiary_party_id,
        gross_amount: payload[:gross_amount],
        currency: currency,
        performed_at: payload[:performed_at],
        due_at: payload[:due_at],
        cutoff_at: payload[:cutoff_at],
        metadata: normalize_metadata(payload[:metadata]),
        allocation: allocation_payload
      }
    end

    def required_string!(value:, code:, message:)
      normalized = value.to_s.strip
      raise_validation_error!(code, message) if normalized.blank?

      normalized
    end

    def normalize_currency(raw_currency)
      raw_currency.to_s.strip.upcase.presence || "BRL"
    end

    def create_primary_allocation!(receivable:, payload:, gross_amount:)
      allocation_payload = payload.fetch(:allocation)
      allocated_party_id = allocation_payload["allocated_party_id"].to_s.strip.presence || receivable.beneficiary_party_id
      allocated_party = Party.where(tenant_id: @tenant_id).find(allocated_party_id)

      physician_party = nil
      physician_party_id = allocation_payload["physician_party_id"].to_s.strip.presence
      if physician_party_id.present?
        physician_party = Party.where(tenant_id: @tenant_id).find(physician_party_id)
      end

      allocation_gross_amount = round_money(parse_decimal(allocation_payload["gross_amount"].presence || gross_amount, field: "allocation.gross_amount"))
      tax_reserve_amount = round_money(parse_decimal(allocation_payload["tax_reserve_amount"].presence || "0", field: "allocation.tax_reserve_amount"))
      eligible_for_anticipation = allocation_payload.key?("eligible_for_anticipation") ? ActiveModel::Type::Boolean.new.cast(allocation_payload["eligible_for_anticipation"]) : true

      ReceivableAllocation.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        sequence: 1,
        allocated_party: allocated_party,
        physician_party: physician_party,
        gross_amount: allocation_gross_amount,
        tax_reserve_amount: tax_reserve_amount,
        status: "OPEN",
        eligible_for_anticipation: eligible_for_anticipation,
        metadata: normalize_hash_metadata(allocation_payload["metadata"])
      )
    end

    def ensure_matching_replay!(existing:, allocation:, payload_hash:, payload:)
      stored_hash = existing.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.present? && stored_hash == payload_hash
      return if stored_hash.blank? && fallback_payload_match?(existing: existing, allocation: allocation, payload: payload)

      raise IdempotencyConflict.new(
        code: "idempotency_key_reused_with_different_payload",
        message: "Idempotency-Key was already used with a different receivable payload."
      )
    end

    def fallback_payload_match?(existing:, allocation:, payload:)
      existing.external_reference.to_s == payload.fetch(:external_reference) &&
        existing.receivable_kind&.code.to_s == payload.fetch(:receivable_kind_code) &&
        existing.debtor_party_id.to_s == payload.fetch(:debtor_party_id) &&
        existing.creditor_party_id.to_s == payload.fetch(:creditor_party_id) &&
        existing.beneficiary_party_id.to_s == payload.fetch(:beneficiary_party_id) &&
        existing.gross_amount.to_d == round_money(parse_decimal(payload.fetch(:gross_amount), field: "gross_amount")) &&
        existing.currency == "BRL" &&
        allocation&.sequence == 1
    end

    def replay_after_race(payload:, payload_hash:)
      existing = Receivable.find_by!(
        tenant_id: @tenant_id,
        external_reference: payload.fetch(:external_reference)
      )
      allocation = existing.receivable_allocations.order(sequence: :asc).first
      ensure_matching_replay!(existing: existing, allocation: allocation, payload_hash: payload_hash, payload: payload)
      Result.new(receivable: existing, allocation: allocation, replayed: true)
    end

    def create_receivable_event!(receivable:, allocation:, occurred_at:)
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      event_type = "RECEIVABLE_PERFORMED"

      payload = {
        receivable_allocation_id: allocation.id,
        external_reference: receivable.external_reference,
        idempotency_key: @idempotency_key,
        gross_amount: decimal_as_string(receivable.gross_amount),
        currency: receivable.currency
      }

      event_hash = Digest::SHA256.hexdigest(
        CanonicalJson.encode(
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
        actor_party_id: nil,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def parse_decimal(raw_value, field:)
      value = BigDecimal(raw_value.to_s)
      return value if value.finite?

      raise_validation_error!("invalid_#{field.tr('.', '_')}", "#{field} is invalid.")
    rescue ArgumentError
      raise_validation_error!("invalid_#{field.tr('.', '_')}", "#{field} is invalid.")
    end

    def parse_time(raw_value, field:)
      case raw_value
      when ActiveSupport::TimeWithZone, Time
        raw_value
      when DateTime
        raw_value.to_time
      else
        value = raw_value.to_s.strip
        raise_validation_error!("invalid_#{field}", "#{field} is invalid.") if value.blank?

        Time.iso8601(value)
      end
    rescue ArgumentError, TypeError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    end

    def round_money(value)
      FinancialRounding.money(value)
    end

    def receivable_payload_hash(payload)
      Digest::SHA256.hexdigest(
        CanonicalJson.encode(
          external_reference: payload.fetch(:external_reference),
          receivable_kind_code: payload.fetch(:receivable_kind_code),
          debtor_party_id: payload.fetch(:debtor_party_id),
          creditor_party_id: payload.fetch(:creditor_party_id),
          beneficiary_party_id: payload.fetch(:beneficiary_party_id),
          gross_amount: round_money(parse_decimal(payload.fetch(:gross_amount), field: "gross_amount")).to_d.to_s("F"),
          currency: payload.fetch(:currency),
          performed_at: payload[:performed_at].presence,
          due_at: payload.fetch(:due_at).to_s,
          cutoff_at: payload[:cutoff_at].presence,
          metadata: payload.fetch(:metadata),
          allocation: payload.fetch(:allocation)
        )
      )
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: nil,
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
        occurred_at: Time.current,
        metadata: normalize_metadata(metadata)
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => log_error
      Rails.logger.error(
        "receivable_create_action_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} request_id=#{@request_id}"
      )
      nil
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

    def normalize_hash_metadata(raw_metadata)
      normalized = normalize_metadata(raw_metadata)
      normalized.is_a?(Hash) ? normalized : {}
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
