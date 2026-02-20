require "digest"

module Receivables
  class SettlePayment
    OPEN_FDIC_STATUSES = Fdic::ExposureCalculator::OPEN_STATUSES
    TARGET_TYPE = "ReceivablePaymentSettlement".freeze
    PAYLOAD_HASH_METADATA_KEY = "_payment_payload_hash".freeze
    ESCROW_EXCESS_OUTBOX_EVENT_TYPE = "RECEIVABLE_ESCROW_EXCESS_PAYOUT_REQUESTED".freeze
    ESCROW_EXCESS_OUTBOX_IDEMPOTENCY_SUFFIX = "escrow_excess_payout".freeze
    FDIC_SETTLEMENT_OUTBOX_EVENT_TYPE = "RECEIVABLE_FIDC_SETTLEMENT_REPORTED".freeze
    FDIC_SETTLEMENT_OUTBOX_IDEMPOTENCY_SUFFIX = "fdic_settlement_report".freeze
    BRL_CURRENCY = "BRL".freeze
    ESCROW_EXCESS_PAYOUT_KIND = "EXCESS".freeze
    FDIC_SETTLEMENT_OPERATION_KIND = "SETTLEMENT_REPORT".freeze

    CallInputs = Struct.new(
      :amount,
      :paid_time,
      :payment_reference,
      :metadata,
      :payload_hash,
      keyword_init: true
    )

    Distribution = Struct.new(
      :cnpj_share_rate,
      :cnpj_amount,
      :beneficiary_pool,
      :obligations,
      :fdic_balance_before,
      :fdic_amount,
      :beneficiary_amount,
      :fdic_balance_after,
      keyword_init: true
    )

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
      actor_party_id: nil,
      actor_role:,
      request_id:,
      idempotency_key:,
      request_ip:,
      user_agent:,
      endpoint_path:,
      http_method:
    )
      @tenant_id = tenant_id
      @actor_party_id = actor_party_id
      @actor_role = actor_role
      @request_id = request_id
      @idempotency_key = idempotency_key.to_s.strip
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
    end

    def call(receivable_id:, paid_amount:, receivable_allocation_id: nil, paid_at: Time.current, payment_reference: nil, metadata: {})
      inputs = build_call_inputs(
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id,
        paid_amount: paid_amount,
        paid_at: paid_at,
        payment_reference: payment_reference,
        metadata: metadata
      )

      process_settlement(
        inputs: inputs,
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id
      )
    rescue ActiveRecord::RecordNotFound => error
      create_failure_log(error:, receivable_id:, payment_reference: inputs&.payment_reference)
      raise
    rescue ValidationError => error
      create_failure_log(error:, receivable_id:, payment_reference: inputs&.payment_reference)
      raise
    rescue ActiveRecord::RecordNotUnique
      recover_after_unique_violation(
        inputs: inputs,
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id
      )
    rescue ActiveRecord::ActiveRecordError => error
      create_failure_log(error:, receivable_id:, payment_reference: inputs&.payment_reference)
      raise
    end

    private

    def process_settlement(inputs:, receivable_id:, receivable_allocation_id:)
      ActiveRecord::Base.transaction do
        existing = find_existing_settlement(inputs.payment_reference)
        return build_replay_result(
          existing: existing,
          inputs: inputs,
          receivable_id: receivable_id,
          receivable_allocation_id: receivable_allocation_id
        ) if existing

        create_new_settlement_result(
          inputs: inputs,
          receivable_id: receivable_id,
          receivable_allocation_id: receivable_allocation_id
        )
      end
    end

    def create_new_settlement_result(inputs:, receivable_id:, receivable_allocation_id:)
      receivable, allocation = load_receivable_and_allocation(
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id
      )
      distribution = calculate_distribution(
        amount: inputs.amount,
        receivable: receivable,
        allocation: allocation,
        paid_time: inputs.paid_time
      )

      settlement = create_settlement_record!(
        receivable: receivable,
        allocation: allocation,
        inputs: inputs,
        distribution: distribution
      )

      settlement_entries = create_settlement_entries!(
        settlement: settlement,
        obligations: distribution.obligations,
        fdic_amount: distribution.fdic_amount,
        settled_at: inputs.paid_time
      )

      run_post_settlement_workflow!(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        settlement_entries: settlement_entries,
        distribution: distribution,
        paid_time: inputs.paid_time,
        payment_reference: inputs.payment_reference
      )

      Result.new(settlement: settlement, settlement_entries: settlement_entries, replayed: false)
    end

    def recover_after_unique_violation(inputs:, receivable_id:, receivable_allocation_id:)
      existing = ReceivablePaymentSettlement.where(tenant_id: @tenant_id, idempotency_key: @idempotency_key).first
      raise unless existing

      ensure_matching_replay!(
        existing: existing,
        payload_hash: inputs&.payload_hash.to_s,
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id,
        paid_amount: inputs&.amount.to_d
      )

      Result.new(
        settlement: existing,
        settlement_entries: settlement_entries_for(existing),
        replayed: true
      )
    end

    def build_call_inputs(receivable_id:, receivable_allocation_id:, paid_amount:, paid_at:, payment_reference:, metadata:)
      raise_validation_error!("missing_idempotency_key", "Idempotency-Key is required.") if @idempotency_key.blank?

      amount = round_money(parse_decimal(paid_amount, field: "paid_amount"))
      raise_validation_error!("invalid_paid_amount", "paid_amount must be greater than zero.") if amount <= 0
      paid_time = parse_time(paid_at, field: "paid_at")
      normalized_payment_reference = payment_reference.to_s.strip.presence || @idempotency_key
      metadata_hash = normalize_metadata(metadata || {})
      payload_hash = payment_payload_hash(
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id,
        paid_amount: amount,
        paid_at: paid_time,
        payment_reference: normalized_payment_reference,
        metadata: metadata_hash
      )

      CallInputs.new(
        amount: amount,
        paid_time: paid_time,
        payment_reference: normalized_payment_reference,
        metadata: metadata_hash,
        payload_hash: payload_hash
      )
    end

    def build_replay_result(existing:, inputs:, receivable_id:, receivable_allocation_id:)
      ensure_matching_replay!(
        existing: existing,
        payload_hash: inputs.payload_hash,
        receivable_id: receivable_id,
        receivable_allocation_id: receivable_allocation_id,
        paid_amount: inputs.amount
      )
      create_action_log!(
        action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_REPLAYED",
        success: true,
        target_id: existing.id,
        metadata: {
          replayed: true,
          payment_reference: inputs.payment_reference,
          idempotency_key: @idempotency_key
        }
      )
      Result.new(
        settlement: existing,
        settlement_entries: settlement_entries_for(existing),
        replayed: true
      )
    end

    def settlement_entries_for(settlement)
      settlement.anticipation_settlement_entries.order(created_at: :asc).to_a
    end

    def load_receivable_and_allocation(receivable_id:, receivable_allocation_id:)
      receivable = Receivable.where(tenant_id: @tenant_id).lock.find(receivable_id)
      allocation = resolve_allocation(receivable:, receivable_allocation_id:)
      [ receivable, allocation ]
    end

    def calculate_distribution(amount:, receivable:, allocation:, paid_time:)
      cnpj_share_rate = resolve_cnpj_share_rate(allocation)
      cnpj_amount = round_money(amount * cnpj_share_rate)
      beneficiary_pool = round_money(amount - cnpj_amount)
      obligations = open_fdic_obligations(receivable:, allocation:, valuation_time: paid_time)
      fdic_balance_before = round_money(obligations.sum { |entry| entry[:outstanding] })
      fdic_amount = round_money([ beneficiary_pool, fdic_balance_before ].min)
      beneficiary_amount = round_money(beneficiary_pool - fdic_amount)
      fdic_balance_after = round_money(fdic_balance_before - fdic_amount)

      Distribution.new(
        cnpj_share_rate: cnpj_share_rate,
        cnpj_amount: cnpj_amount,
        beneficiary_pool: beneficiary_pool,
        obligations: obligations,
        fdic_balance_before: fdic_balance_before,
        fdic_amount: fdic_amount,
        beneficiary_amount: beneficiary_amount,
        fdic_balance_after: fdic_balance_after
      )
    end

    def create_settlement_record!(receivable:, allocation:, inputs:, distribution:)
      ReceivablePaymentSettlement.create!(
        tenant_id: @tenant_id,
        receivable: receivable,
        receivable_allocation: allocation,
        paid_amount: inputs.amount,
        cnpj_amount: distribution.cnpj_amount,
        fdic_amount: distribution.fdic_amount,
        beneficiary_amount: distribution.beneficiary_amount,
        fdic_balance_before: distribution.fdic_balance_before,
        fdic_balance_after: distribution.fdic_balance_after,
        paid_at: inputs.paid_time,
        payment_reference: inputs.payment_reference,
        idempotency_key: @idempotency_key,
        request_id: @request_id,
        metadata: inputs.metadata.merge(
          PAYLOAD_HASH_METADATA_KEY => inputs.payload_hash,
          "cnpj_share_rate" => decimal_as_string(distribution.cnpj_share_rate),
          "idempotency_key" => @idempotency_key,
          "replayed" => false
        )
      )
    end

    def run_post_settlement_workflow!(
      settlement:,
      receivable:,
      allocation:,
      settlement_entries:,
      distribution:,
      paid_time:,
      payment_reference:
    )
      post_ledger_entries!(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        cnpj_amount: distribution.cnpj_amount,
        fdic_amount: distribution.fdic_amount,
        beneficiary_amount: distribution.beneficiary_amount,
        paid_at: paid_time
      )
      update_statuses_after_payment!(receivable:, allocation:)
      create_receivable_event!(
        receivable: receivable,
        settlement: settlement,
        settlement_entries: settlement_entries,
        occurred_at: paid_time
      )
      create_escrow_excess_outbox_event!(
        settlement: settlement,
        receivable: receivable,
        beneficiary_amount: distribution.beneficiary_amount
      )
      create_fdic_settlement_outbox_event!(
        settlement: settlement,
        receivable: receivable,
        fdic_amount: distribution.fdic_amount
      )
      create_action_log!(
        action_type: "RECEIVABLE_PAYMENT_SETTLEMENT_CREATED",
        success: true,
        target_id: settlement.id,
        metadata: {
          replayed: false,
          payment_reference: payment_reference,
          idempotency_key: @idempotency_key,
          paid_amount: decimal_as_string(settlement.paid_amount),
          cnpj_amount: decimal_as_string(distribution.cnpj_amount),
          fdic_amount: decimal_as_string(distribution.fdic_amount),
          beneficiary_amount: decimal_as_string(distribution.beneficiary_amount)
        }
      )
    end

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

      obligations.each do |obligation|
        break if remaining_fdic <= 0

        settlement_entry, remaining_fdic = settle_fdic_obligation!(
          settlement: settlement,
          obligation: obligation,
          remaining_fdic: remaining_fdic,
          settled_at: settled_at
        )
        entries << settlement_entry if settlement_entry
      end

      entries
    end

    def settle_fdic_obligation!(settlement:, obligation:, remaining_fdic:, settled_at:)
      anticipation_request = obligation[:anticipation_request]
      outstanding = obligation[:outstanding]
      settled_amount = round_money([ remaining_fdic, outstanding ].min)
      return [ nil, remaining_fdic ] if settled_amount <= 0

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

      remaining_fdic_after = round_money(remaining_fdic - settled_amount)
      mark_anticipation_settled_if_fully_paid!(
        anticipation_request: anticipation_request,
        outstanding: outstanding,
        settled_amount: settled_amount,
        settled_at: settled_at
      )

      [ settlement_entry, remaining_fdic_after ]
    end

    def mark_anticipation_settled_if_fully_paid!(anticipation_request:, outstanding:, settled_amount:, settled_at:)
      remaining_request_outstanding = round_money(outstanding - settled_amount)
      return unless remaining_request_outstanding <= 0
      return if anticipation_request.status == "SETTLED"

      anticipation_request.transition_status!("SETTLED", settled_at: settled_at)
    end

    def post_ledger_entries!(settlement:, receivable:, allocation:, cnpj_amount:, fdic_amount:, beneficiary_amount:, paid_at:)
      Ledger::PostSettlement.new(
        tenant_id: @tenant_id,
        request_id: @request_id,
        actor_party_id: @actor_party_id,
        actor_role: @actor_role
      ).call(
        settlement: settlement,
        receivable: receivable,
        allocation: allocation,
        cnpj_amount: cnpj_amount,
        fdic_amount: fdic_amount,
        beneficiary_amount: beneficiary_amount,
        paid_at: paid_at
      )
    rescue Ledger::PostTransaction::IdempotencyConflict => error
      raise IdempotencyConflict.new(code: error.code, message: error.message)
    rescue Ledger::PostTransaction::ValidationError => error
      raise ValidationError.new(code: error.code, message: error.message)
    rescue ActiveRecord::StatementInvalid => error
      if error.message.match?(
        /unbalanced ledger transaction|incomplete ledger transaction|inconsistent txn_entry_count|inconsistent source linkage|ledger transaction source mismatch|ledger transaction payment_reference mismatch|payment_reference is required for settlement ledger transaction/
      )
        raise ValidationError.new(code: "ledger_invariant_violation", message: "Ledger invariants were violated.")
      end

      raise
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

    def find_existing_settlement(payment_reference)
      by_idempotency = ReceivablePaymentSettlement.lock.find_by(tenant_id: @tenant_id, idempotency_key: @idempotency_key)
      return by_idempotency if by_idempotency
      return nil if payment_reference.blank?

      ReceivablePaymentSettlement.lock.find_by(tenant_id: @tenant_id, payment_reference: payment_reference)
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
        idempotency_key: settlement.idempotency_key,
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
        actor_party_id: @actor_party_id,
        actor_role: @actor_role,
        occurred_at: occurred_at,
        request_id: @request_id,
        prev_hash: prev_hash,
        event_hash: event_hash,
        payload: payload
      )
    end

    def create_escrow_excess_outbox_event!(settlement:, receivable:, beneficiary_amount:)
      return if beneficiary_amount.to_d <= 0

      provider = Integrations::Escrow::ProviderConfig.default_provider(tenant_id: @tenant_id)
      recipient_party = Party.where(tenant_id: @tenant_id).find(receivable.beneficiary_party_id)
      amount = decimal_as_string(beneficiary_amount)
      payout_idempotency_key = "#{settlement.id}:#{ESCROW_EXCESS_OUTBOX_IDEMPOTENCY_SUFFIX}"
      account_idempotency_key = "#{recipient_party.id}:escrow_account"
      receivable_origin = receivable_origin_payload(receivable)

      payload_hash = escrow_excess_payload_hash(
        settlement: settlement,
        recipient_party_id: recipient_party.id,
        provider: provider,
        amount: amount,
        receivable_origin: receivable_origin
      )
      payload = build_escrow_excess_outbox_payload(
        settlement: settlement,
        receivable: receivable,
        recipient_party: recipient_party,
        amount: amount,
        provider: provider,
        receivable_origin: receivable_origin,
        payout_idempotency_key: payout_idempotency_key,
        account_idempotency_key: account_idempotency_key,
        payload_hash: payload_hash
      )

      create_outbox_event_with_conflict_check!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: settlement.id,
        event_type: ESCROW_EXCESS_OUTBOX_EVENT_TYPE,
        idempotency_key: payout_idempotency_key,
        payload: payload,
        payload_hash: payload_hash,
        conflict_code: "escrow_payout_idempotency_conflict",
        conflict_message: "Escrow payout idempotency key was already used with a different payload."
      )
    end

    def create_fdic_settlement_outbox_event!(settlement:, receivable:, fdic_amount:)
      return if fdic_amount.to_d <= 0

      provider = Integrations::Fdic::ProviderConfig.default_provider(tenant_id: @tenant_id)
      amount = decimal_as_string(fdic_amount)
      report_idempotency_key = "#{settlement.id}:#{FDIC_SETTLEMENT_OUTBOX_IDEMPOTENCY_SUFFIX}"
      receivable_origin = receivable_origin_payload(receivable)
      payload_hash = fdic_settlement_payload_hash(
        settlement: settlement,
        provider: provider,
        amount: amount,
        receivable_origin: receivable_origin
      )
      payload = build_fdic_settlement_outbox_payload(
        settlement: settlement,
        provider: provider,
        amount: amount,
        receivable_origin: receivable_origin,
        report_idempotency_key: report_idempotency_key,
        payload_hash: payload_hash
      )

      create_outbox_event_with_conflict_check!(
        tenant_id: @tenant_id,
        aggregate_type: TARGET_TYPE,
        aggregate_id: settlement.id,
        event_type: FDIC_SETTLEMENT_OUTBOX_EVENT_TYPE,
        idempotency_key: report_idempotency_key,
        payload: payload,
        payload_hash: payload_hash,
        conflict_code: "fdic_settlement_idempotency_conflict",
        conflict_message: "FDIC settlement idempotency key was already used with a different payload."
      )
    end

    def create_outbox_event_with_conflict_check!(
      tenant_id:,
      aggregate_type:,
      aggregate_id:,
      event_type:,
      idempotency_key:,
      payload:,
      payload_hash:,
      conflict_code:,
      conflict_message:
    )
      OutboxEvent.create!(
        tenant_id: tenant_id,
        aggregate_type: aggregate_type,
        aggregate_id: aggregate_id,
        event_type: event_type,
        status: "PENDING",
        idempotency_key: idempotency_key,
        payload: payload
      )
    rescue ActiveRecord::RecordNotUnique
      assert_outbox_payload_hash_matches!(
        idempotency_key: idempotency_key,
        payload_hash: payload_hash,
        code: conflict_code,
        message: conflict_message
      )
    end

    def build_escrow_excess_outbox_payload(
      settlement:,
      receivable:,
      recipient_party:,
      amount:,
      provider:,
      receivable_origin:,
      payout_idempotency_key:,
      account_idempotency_key:,
      payload_hash:
    )
      {
        "payload_hash" => payload_hash,
        "settlement_id" => settlement.id,
        "receivable_id" => receivable.id,
        "recipient_party_id" => recipient_party.id,
        "amount" => amount,
        "currency" => BRL_CURRENCY,
        "provider" => provider,
        "payout_kind" => ESCROW_EXCESS_PAYOUT_KIND,
        "payment_reference" => settlement.payment_reference,
        "payout_idempotency_key" => payout_idempotency_key,
        "account_idempotency_key" => account_idempotency_key,
        "provider_request_control_key" => payout_idempotency_key,
        "request_id" => @request_id,
        "expected_taxpayer_id" => recipient_party.document_number,
        "receivable_origin" => receivable_origin
      }
    end

    def build_fdic_settlement_outbox_payload(
      settlement:,
      provider:,
      amount:,
      receivable_origin:,
      report_idempotency_key:,
      payload_hash:
    )
      {
        "payload_hash" => payload_hash,
        "settlement_id" => settlement.id,
        "receivable_id" => settlement.receivable_id,
        "receivable_allocation_id" => settlement.receivable_allocation_id,
        "payment_reference" => settlement.payment_reference,
        "amount" => amount,
        "currency" => BRL_CURRENCY,
        "provider" => provider,
        "operation_kind" => FDIC_SETTLEMENT_OPERATION_KIND,
        "operation_idempotency_key" => report_idempotency_key,
        "provider_request_control_key" => report_idempotency_key,
        "fdic_amount" => amount,
        "fdic_balance_before" => decimal_as_string(settlement.fdic_balance_before),
        "fdic_balance_after" => decimal_as_string(settlement.fdic_balance_after),
        "receivable_origin" => receivable_origin
      }
    end

    def assert_outbox_payload_hash_matches!(idempotency_key:, payload_hash:, code:, message:)
      existing = OutboxEvent.find_by!(tenant_id: @tenant_id, idempotency_key: idempotency_key)
      stored_hash = existing.payload&.dig("payload_hash").to_s
      return if stored_hash.blank? || stored_hash == payload_hash

      raise IdempotencyConflict.new(code: code, message: message)
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        tenant_id: @tenant_id,
        actor_party_id: @actor_party_id,
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
        actor_party_id: @actor_party_id,
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
          idempotency_key: @idempotency_key,
          error_class: error.class.name,
          error_code: error.respond_to?(:code) ? error.code : "not_found",
          error_message: error.message
        }
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked => log_error
      Rails.logger.error(
        "settle_payment_failure_log_write_error " \
        "error_class=#{log_error.class.name} error_message=#{log_error.message} " \
        "original_error_class=#{error.class.name} request_id=#{@request_id}"
      )
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

    def escrow_excess_payload_hash(settlement:, recipient_party_id:, provider:, amount:, receivable_origin:)
      Digest::SHA256.hexdigest(
        canonical_json(
          settlement_id: settlement.id,
          receivable_id: settlement.receivable_id,
          recipient_party_id: recipient_party_id,
          provider: provider,
          amount: amount,
          currency: "BRL",
          payout_kind: "EXCESS",
          receivable_origin: receivable_origin
        )
      )
    end

    def fdic_settlement_payload_hash(settlement:, provider:, amount:, receivable_origin:)
      Digest::SHA256.hexdigest(
        canonical_json(
          settlement_id: settlement.id,
          receivable_id: settlement.receivable_id,
          receivable_allocation_id: settlement.receivable_allocation_id,
          payment_reference: settlement.payment_reference,
          provider: provider,
          amount: amount,
          currency: "BRL",
          operation_kind: "SETTLEMENT_REPORT",
          receivable_origin: receivable_origin
        )
      )
    end

    def receivable_origin_payload(receivable)
      hospital_party = receivable.debtor_party
      ownership = active_hospital_ownership(hospital_party_id: receivable.debtor_party_id)

      {
        "receivable_id" => receivable.id,
        "external_reference" => receivable.external_reference,
        "hospital_party_id" => receivable.debtor_party_id,
        "hospital_legal_name" => hospital_party.legal_name,
        "hospital_document_number" => hospital_party.document_number,
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
