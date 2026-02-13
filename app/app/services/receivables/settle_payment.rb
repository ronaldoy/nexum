require "digest"

module Receivables
  class SettlePayment
    OPEN_FDIC_STATUSES = Fdic::ExposureCalculator::OPEN_STATUSES
    TARGET_TYPE = "ReceivablePaymentSettlement".freeze
    PAYLOAD_HASH_METADATA_KEY = "_payment_payload_hash".freeze

    Result = Struct.new(:settlement, :settlement_entries, :replayed, keyword_init: true) do
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
      request_ip:,
      user_agent:,
      endpoint_path:,
      http_method:
    )
      @tenant_id = tenant_id
      @actor_role = actor_role
      @request_id = request_id
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(receivable_id:, paid_amount:, receivable_allocation_id: nil, paid_at: Time.current, payment_reference: nil, metadata: {})
      amount = round_money(parse_decimal(paid_amount, field: "paid_amount"))
      raise_validation_error!("invalid_paid_amount", "paid_amount must be greater than zero.") if amount <= 0
      paid_time = parse_time(paid_at, field: "paid_at")

      metadata_hash = normalize_metadata(metadata || {})
      payload_hash = payment_payload_hash(
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id,
        paid_amount: amount,
        paid_at: paid_time,
        payment_reference: payment_reference,
        metadata: metadata_hash
      )

      settlement = nil
      settlement_entries = []
      replayed = false

      ActiveRecord::Base.transaction do
        if payment_reference.present?
          existing = ReceivablePaymentSettlement.lock.find_by(tenant_id: @tenant_id, payment_reference: payment_reference)
          if existing
            ensure_matching_replay!(existing:, payload_hash:, receivable_id:, receivable_allocation_id:, paid_amount: amount)
            create_action_log!(
              action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_REPLAYED",
              success: true,
              target_id: existing.id,
              metadata: { replayed: true, payment_reference: payment_reference }
            )
            return Result.new(
              settlement: existing,
              settlement_entries: existing.anticipation_settlement_entries.order(created_at: :asc).to_a,
              replayed: true
            )
          end
        end

        receivable = Receivable.where(tenant_id: @tenant_id).lock.find(receivable_id)
        allocation = resolve_allocation(receivable:, receivable_allocation_id:)

        cnpj_share_rate = resolve_cnpj_share_rate(allocation)
        cnpj_amount = round_money(amount * cnpj_share_rate)
        beneficiary_pool = round_money(amount - cnpj_amount)

        obligations = open_fdic_obligations(receivable:, allocation:, valuation_time: paid_time)
        fdic_balance_before = round_money(obligations.sum { |entry| entry[:outstanding] })
        fdic_amount = round_money([ beneficiary_pool, fdic_balance_before ].min)
        beneficiary_amount = round_money(beneficiary_pool - fdic_amount)
        fdic_balance_after = round_money(fdic_balance_before - fdic_amount)

        settlement = ReceivablePaymentSettlement.create!(
          tenant_id: @tenant_id,
          receivable: receivable,
          receivable_allocation: allocation,
          paid_amount: amount,
          cnpj_amount: cnpj_amount,
          fdic_amount: fdic_amount,
          beneficiary_amount: beneficiary_amount,
          fdic_balance_before: fdic_balance_before,
          fdic_balance_after: fdic_balance_after,
          paid_at: paid_time,
          payment_reference: payment_reference,
          request_id: @request_id,
          metadata: metadata_hash.merge(
            PAYLOAD_HASH_METADATA_KEY => payload_hash,
            "cnpj_share_rate" => decimal_as_string(cnpj_share_rate),
            "replayed" => false
          )
        )

        settlement_entries = create_settlement_entries!(
          settlement: settlement,
          obligations: obligations,
          fdic_amount: fdic_amount,
          settled_at: paid_time
        )

        post_ledger_entries!(
          settlement: settlement,
          receivable: receivable,
          allocation: allocation,
          cnpj_amount: cnpj_amount,
          fdic_amount: fdic_amount,
          beneficiary_amount: beneficiary_amount,
          paid_at: paid_time
        )

        update_statuses_after_payment!(receivable:, allocation:)

        create_receivable_event!(
          receivable: receivable,
          settlement: settlement,
          settlement_entries: settlement_entries,
          occurred_at: paid_time
        )

        create_action_log!(
          action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_CREATED",
          success: true,
          target_id: settlement.id,
          metadata: {
            replayed: false,
            payment_reference: payment_reference,
            paid_amount: decimal_as_string(amount),
            cnpj_amount: decimal_as_string(cnpj_amount),
            fdic_amount: decimal_as_string(fdic_amount),
            beneficiary_amount: decimal_as_string(beneficiary_amount)
          }
        )
      end

      Result.new(settlement:, settlement_entries:, replayed:)
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error:, receivable_id:, payment_reference:)
      raise
    rescue ValidationError => error
      create_failure_log(error:, receivable_id:, payment_reference:)
      raise
    end

    private

    def parse_decimal(raw_value, field:)
      value = BigDecimal(raw_value.to_s)
      return value if value.finite?

      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
    rescue ArgumentError
      raise_validation_error!("invalid_#{field}", "#{field} is invalid.")
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

    def round_rate(value)
      FinancialRounding.rate(value)
    end

    def resolve_allocation(receivable:, receivable_allocation_id:)
      return ReceivableAllocation.where(tenant_id: @tenant_id, receivable_id: receivable.id).lock.find(receivable_allocation_id) if receivable_allocation_id.present?

      allocations = receivable.receivable_allocations.order(sequence: :asc).lock.to_a
      return nil if allocations.empty?
      return allocations.first if allocations.one?

      raise_validation_error!(
        "receivable_allocation_required",
        "receivable_allocation_id is required when receivable has multiple allocations."
      )
    end

    def resolve_cnpj_share_rate(allocation)
      return BigDecimal("0") if allocation.blank?

      metadata = normalize_metadata(allocation.metadata || {})
      split_metadata = metadata["cnpj_split"]

      if split_metadata.is_a?(Hash) && split_metadata["applied"] == true
        return round_rate(parse_decimal(split_metadata["cnpj_share_rate"], field: "cnpj_share_rate"))
      end

      return BigDecimal("0") if allocation.gross_amount.to_d <= 0 || allocation.tax_reserve_amount.to_d <= 0

      round_rate(allocation.tax_reserve_amount.to_d / allocation.gross_amount.to_d)
    rescue ValidationError
      BigDecimal("0")
    end

    def open_fdic_obligations(receivable:, allocation:, valuation_time:)
      exposure_calculator = Fdic::ExposureCalculator.new(valuation_time: valuation_time)

      scope = AnticipationRequest.where(
        tenant_id: @tenant_id,
        receivable_id: receivable.id,
        status: OPEN_FDIC_STATUSES
      )
      scope = scope.where(receivable_allocation_id: allocation.id) if allocation

      scope.order(requested_at: :asc, created_at: :asc).map do |anticipation_request|
        exposure_metrics = exposure_calculator.call(
          anticipation_request: anticipation_request,
          due_at: receivable.due_at
        )
        outstanding = exposure_metrics.effective_contractual_exposure
        next if outstanding <= 0

        {
          anticipation_request: anticipation_request,
          outstanding: outstanding
        }
      end.compact
    end

    def create_settlement_entries!(settlement:, obligations:, fdic_amount:, settled_at:)
      remaining_fdic = fdic_amount
      entries = []

      obligations.each do |entry|
        break if remaining_fdic <= 0

        anticipation_request = entry[:anticipation_request]
        outstanding = entry[:outstanding]
        settled_amount = round_money([ remaining_fdic, outstanding ].min)
        next if settled_amount <= 0

        settlement_entry = AnticipationSettlementEntry.create!(
          tenant_id: @tenant_id,
          receivable_payment_settlement: settlement,
          anticipation_request: anticipation_request,
          settled_amount: settled_amount,
          settled_at: settled_at,
          metadata: {
            receivable_id: settlement.receivable_id,
            receivable_allocation_id: settlement.receivable_allocation_id
          }
        )
        entries << settlement_entry

        remaining_fdic = round_money(remaining_fdic - settled_amount)
        remaining_request_outstanding = round_money(outstanding - settled_amount)
        if remaining_request_outstanding <= 0 && anticipation_request.status != "SETTLED"
          anticipation_request.update!(status: "SETTLED", settled_at: settled_at)
        end
      end

      entries
    end

    def post_ledger_entries!(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:, paid_at:)
      Ledger::PostSettlement.new(tenant_id: @tenant_id, request_id: @request_id).call(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        cnpj_amount: cnpj_amount,
        fdic_amount: fdic_amount,
        beneficiary_amount: beneficiary_amount,
        paid_at: paid_at
      )
    end

    def update_statuses_after_payment!(receivable:, allocation:)
      if allocation
        allocation_paid_total = ReceivablePaymentSettlement.where(
          tenant_id: @tenant_id,
          receivable_allocation_id: allocation.id
        ).sum(:paid_amount).to_d
        if allocation.status != "SETTLED" && allocation_paid_total >= allocation.gross_amount.to_d
          allocation.update!(status: "SETTLED")
        end

        if receivable.receivable_allocations.where.not(status: "SETTLED").none? && receivable.status != "SETTLED"
          receivable.update!(status: "SETTLED")
        end
        return
      end

      receivable_paid_total = ReceivablePaymentSettlement.where(
        tenant_id: @tenant_id,
        receivable_id: receivable.id
      ).sum(:paid_amount).to_d
      if receivable.status != "SETTLED" && receivable_paid_total >= receivable.gross_amount.to_d
        receivable.update!(status: "SETTLED")
      end
    end

    def ensure_matching_replay!(existing:, payload_hash:, receivable_id:, receivable_allocation_id:, paid_amount:)
      stored_hash = existing.metadata&.[](PAYLOAD_HASH_METADATA_KEY).to_s
      return if stored_hash.present? && stored_hash == payload_hash
      return if stored_hash.blank? && fallback_replay_match?(existing:, receivable_id:, receivable_allocation_id:, paid_amount:)

      raise IdempotencyConflict.new(
        code: "payment_reference_reused_with_different_payload",
        message: "payment_reference was already used with a different payload."
      )
    end

    def fallback_replay_match?(existing:, receivable_id:, receivable_allocation_id:, paid_amount:)
      existing.receivable_id.to_s == receivable_id.to_s &&
        existing.receivable_allocation_id.to_s == receivable_allocation_id.to_s &&
        existing.paid_amount.to_d == paid_amount.to_d
    end

    def create_receivable_event!(receivable:, settlement:, settlement_entries:, occurred_at:)
      previous = receivable.receivable_events.order(sequence: :desc).limit(1).pluck(:sequence, :event_hash).first
      sequence = previous ? previous[0] + 1 : 1
      prev_hash = previous&.[](1)
      event_type = "RECEIVABLE_PAYMENT_SETTLED"

      payload = {
        settlement_id: settlement.id,
        receivable_allocation_id: settlement.receivable_allocation_id,
        payment_reference: settlement.payment_reference,
        paid_amount: decimal_as_string(settlement.paid_amount),
        cnpj_amount: decimal_as_string(settlement.cnpj_amount),
        fdic_amount: decimal_as_string(settlement.fdic_amount),
        beneficiary_amount: decimal_as_string(settlement.beneficiary_amount),
        fdic_balance_before: decimal_as_string(settlement.fdic_balance_before),
        fdic_balance_after: decimal_as_string(settlement.fdic_balance_after),
        settlement_entries: settlement_entries.map do |entry|
          {
            id: entry.id,
            anticipation_request_id: entry.anticipation_request_id,
            settled_amount: decimal_as_string(entry.settled_amount)
          }
        end
      }

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
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
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
    end

    def create_failure_log(error:, receivable_id:, payment_reference:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_FAILED",
        ip_address: @request_ip.presence || "0.0.0.0",
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: "API",
        target_type: "Receivable",
        target_id: receivable_id,
        success: false,
        occurred_at: Time.current,
        metadata: {
          payment_reference: payment_reference,
          error_class: error.class.name,
          error_code: error.respond_to?(:code) ? error.code : "not_found",
          error_message: error.message
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil
    end

    def payment_payload_hash(receivable_id:, receivable_allocation_id:, paid_amount:, paid_at:, payment_reference:, metadata:)
      Digest::SHA256.hexdigest(
        canonical_json(
          receivable_id: receivable_id.to_s,
          receivable_allocation_id: receivable_allocation_id.to_s,
          paid_amount: decimal_as_string(paid_amount),
          paid_at: paid_at.utc.iso8601(6),
          payment_reference: payment_reference.to_s,
          metadata: metadata
        )
      )
    end

    def canonical_json(value)
      case value
      when Hash
        "{" + value.sort_by { |k, _| k.to_s }.map { |k, v| "#{k.to_s.to_json}:#{canonical_json(v)}" }.join(",") + "}"
      when Array
        "[" + value.map { |entry| canonical_json(entry) }.join(",") + "]"
      when BigDecimal
        decimal_as_string(value).to_json
      else
        value.to_json
      end
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
