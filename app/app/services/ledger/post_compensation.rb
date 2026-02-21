module Ledger
  class PostCompensation
    COMPENSATION_REQUESTED_ACTION = "LEDGER_COMPENSATION_REQUESTED".freeze
    COMPENSATION_POSTED_ACTION = "LEDGER_COMPENSATION_POSTED".freeze
    COMPENSATION_FAILED_ACTION = "LEDGER_COMPENSATION_FAILED".freeze

    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    class AuditLogError < ValidationError; end
    CallInputs = Struct.new(
      :original_txn_id,
      :compensation_txn_id,
      :compensation_reference,
      :posted_at,
      :source_type,
      :source_id,
      :reason,
      :metadata,
      keyword_init: true
    )

    def initialize(
      tenant_id:,
      request_id:,
      request_ip:,
      user_agent:,
      endpoint_path:,
      http_method:,
      actor_party_id: nil,
      channel: "ADMIN"
    )
      @tenant_id = tenant_id
      @request_id = request_id
      @request_ip = request_ip
      @user_agent = user_agent
      @endpoint_path = endpoint_path
      @http_method = http_method
      @actor_party_id = actor_party_id
      @channel = channel
    end

    def call(
      original_txn_id:,
      compensation_txn_id:,
      compensation_reference:,
      posted_at:,
      source_type:,
      source_id:,
      reason:,
      metadata: {}
    )
      inputs = build_call_inputs(
        original_txn_id: original_txn_id,
        compensation_txn_id: compensation_txn_id,
        compensation_reference: compensation_reference,
        posted_at: posted_at,
        source_type: source_type,
        source_id: source_id,
        reason: reason,
        metadata: metadata
      )

      execute_compensation(inputs)
    rescue StandardError => error
      create_action_log_safely!(
        action_type: COMPENSATION_FAILED_ACTION,
        success: false,
        target_id: resolve_failure_target_id(inputs:, fallback_target_id: compensation_txn_id),
        metadata: failure_metadata(
          original_txn_id: inputs&.original_txn_id || original_txn_id,
          compensation_reference: inputs&.compensation_reference || compensation_reference,
          error: error
        )
      )
      raise
    end

    private

    def resolve_failure_target_id(inputs:, fallback_target_id:)
      inputs&.compensation_txn_id || fallback_target_id
    end

    def build_call_inputs(
      original_txn_id:,
      compensation_txn_id:,
      compensation_reference:,
      posted_at:,
      source_type:,
      source_id:,
      reason:,
      metadata:
    )
      validate_call_inputs!(reason:, compensation_reference:, source_type:, source_id:)

      CallInputs.new(
        original_txn_id: original_txn_id,
        compensation_txn_id: compensation_txn_id,
        compensation_reference: compensation_reference,
        posted_at: normalize_posted_at(posted_at),
        source_type: source_type,
        source_id: source_id,
        reason: reason,
        metadata: metadata
      )
    end

    def execute_compensation(inputs)
      original_entries = load_original_entries!(inputs.original_txn_id)
      compensation_metadata = build_compensation_metadata!(
        metadata: inputs.metadata,
        original_txn_id: inputs.original_txn_id,
        compensation_txn_id: inputs.compensation_txn_id,
        compensation_reference: inputs.compensation_reference,
        reason: inputs.reason
      )
      entries = build_compensation_entries(original_entries: original_entries, compensation_metadata: compensation_metadata)
      result = post_compensation_transaction(
        inputs: inputs,
        original_entries: original_entries,
        entries: entries
      )
      log_compensation_success!(compensation_txn_id: inputs.compensation_txn_id, compensation_metadata: compensation_metadata)
      result
    end

    def log_compensation_success!(compensation_txn_id:, compensation_metadata:)
      create_action_log!(
        action_type: COMPENSATION_POSTED_ACTION,
        success: true,
        target_id: compensation_txn_id,
        metadata: compensation_metadata
      )
    end

    def validate_call_inputs!(reason:, compensation_reference:, source_type:, source_id:)
      raise_validation_error!("reason_required", "reason is required.") if reason.to_s.strip.blank?
      raise_validation_error!("compensation_reference_required", "compensation_reference is required.") if compensation_reference.to_s.strip.blank?
      validate_compensation_source!(source_type:, source_id:)
    end

    def load_original_entries!(original_txn_id)
      entries = LedgerEntry
        .where(tenant_id: @tenant_id, txn_id: original_txn_id)
        .order(:entry_position, :created_at)
        .to_a
      raise_validation_error!("original_transaction_not_found", "original transaction was not found.") if entries.empty?

      entries
    end

    def build_compensation_metadata!(metadata:, original_txn_id:, compensation_txn_id:, compensation_reference:, reason:)
      base_metadata = base_compensation_metadata(
        metadata: metadata,
        original_txn_id: original_txn_id,
        compensation_reference: compensation_reference,
        reason: reason
      )
      audit_log = create_action_log!(
        action_type: COMPENSATION_REQUESTED_ACTION,
        success: true,
        target_id: compensation_txn_id,
        metadata: base_metadata
      )
      metadata_with_audit = base_metadata.deep_dup
      metadata_with_audit["compensation"]["audit_action_log_id"] = audit_log.id
      metadata_with_audit
    end

    def base_compensation_metadata(metadata:, original_txn_id:, compensation_reference:, reason:)
      normalize_metadata(metadata).merge(
        "compensation" => {
          "original_txn_id" => original_txn_id.to_s,
          "reason" => reason.to_s,
          "compensation_reference" => compensation_reference.to_s
        }
      )
    end

    def build_compensation_entries(original_entries:, compensation_metadata:)
      original_entries.map { |entry| compensation_entry(original_entry: entry, compensation_metadata: compensation_metadata) }
    end

    def compensation_entry(original_entry:, compensation_metadata:)
      {
        account_code: original_entry.account_code,
        entry_side: opposite_side(original_entry.entry_side),
        amount: original_entry.amount.to_d,
        party_id: original_entry.party_id,
        metadata: compensation_metadata.merge("original_entry_id" => original_entry.id)
      }
    end

    def post_compensation_transaction(inputs:, original_entries:, entries:)
      post_transaction_service.call(
        txn_id: inputs.compensation_txn_id,
        receivable_id: original_entries.first.receivable_id,
        payment_reference: compensation_payment_reference(inputs.compensation_reference),
        posted_at: inputs.posted_at,
        source_type: inputs.source_type,
        source_id: inputs.source_id,
        entries: entries
      )
    end

    def post_transaction_service
      @post_transaction_service ||= PostTransaction.new(
        tenant_id: @tenant_id,
        request_id: @request_id,
        actor_party_id: @actor_party_id,
        actor_role: @channel
      )
    end

    def compensation_payment_reference(compensation_reference)
      "COMPENSATION:#{compensation_reference}"
    end

    def validate_compensation_source!(source_type:, source_id:)
      raise_validation_error!("source_type_required", "source_type is required.") if source_type.to_s.strip.blank?
      raise_validation_error!("source_id_required", "source_id is required.") if source_id.to_s.strip.blank?
    end

    def normalize_posted_at(value)
      raise_validation_error!("posted_at_required", "posted_at is required.") if value.nil?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      parsed = Time.zone.parse(value.to_s)
      raise_validation_error!("invalid_posted_at", "posted_at is invalid.") if parsed.nil?

      parsed
    rescue ArgumentError, TypeError
      raise_validation_error!("invalid_posted_at", "posted_at is invalid.")
    end

    def opposite_side(side)
      side == "DEBIT" ? "CREDIT" : "DEBIT"
    end

    def normalize_metadata(value)
      return {} if value.nil?
      return value.deep_stringify_keys if value.is_a?(Hash)

      raise_validation_error!("invalid_metadata", "metadata must be an object.")
    end

    def failure_metadata(original_txn_id:, compensation_reference:, error:)
      {
        compensation: {
          original_txn_id: original_txn_id.to_s,
          compensation_reference: compensation_reference.to_s
        },
        error_class: error.class.name,
        error_message: error.message
      }
    end

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
        action_log_attributes(
          action_type: action_type,
          success: success,
          target_id: target_id,
          metadata: metadata
        )
      )
    rescue ActiveRecord::RecordInvalid => error
      raise_audit_log_error!(action_type: action_type, message: error.record.errors.full_messages.join(", "))
    rescue ActiveRecord::ActiveRecordError => error
      raise_audit_log_error!(action_type: action_type, message: error.message)
    end

    def action_log_attributes(action_type:, success:, target_id:, metadata:)
      {
        tenant_id: @tenant_id,
        actor_party_id: @actor_party_id,
        action_type: action_type,
        ip_address: @request_ip,
        user_agent: @user_agent,
        request_id: @request_id,
        endpoint_path: @endpoint_path,
        http_method: @http_method,
        channel: @channel,
        target_type: "LedgerTransaction",
        target_id: target_id,
        success: success,
        occurred_at: Time.current,
        metadata: metadata
      }
    end

    def raise_audit_log_error!(action_type:, message:)
      raise AuditLogError.new(
        code: "audit_log_write_failed",
        message: "failed to create action log #{action_type}: #{message}"
      )
    end

    def create_action_log_safely!(action_type:, success:, target_id:, metadata:)
      create_action_log!(
        action_type: action_type,
        success: success,
        target_id: target_id,
        metadata: metadata
      )
    rescue StandardError => error
      return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

      log_action_log_failure(action_type: action_type, target_id: target_id, error: error)
    end

    def log_action_log_failure(action_type:, target_id:, error:)
      Rails.logger.error(
        "ledger_compensation_action_log_failure action=#{action_type} tenant_id=#{@tenant_id} " \
          "target_id=#{target_id} error_class=#{error.class.name} error_message=#{error.message}"
      )
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
