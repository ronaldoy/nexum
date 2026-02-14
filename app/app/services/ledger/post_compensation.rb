module Ledger
  class PostCompensation
    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    class AuditLogError < ValidationError; end

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
      raise_validation_error!("reason_required", "reason is required.") if reason.to_s.strip.blank?
      raise_validation_error!("compensation_reference_required", "compensation_reference is required.") if compensation_reference.to_s.strip.blank?
      validate_compensation_source!(source_type:, source_id:)
      posted_at = normalize_posted_at(posted_at)

      original_entries = LedgerEntry
        .where(tenant_id: @tenant_id, txn_id: original_txn_id)
        .order(:entry_position, :created_at)
        .to_a

      if original_entries.empty?
        raise_validation_error!("original_transaction_not_found", "original transaction was not found.")
      end

      base_metadata = normalize_metadata(metadata).merge(
        "compensation" => {
          "original_txn_id" => original_txn_id.to_s,
          "reason" => reason.to_s,
          "compensation_reference" => compensation_reference.to_s
        }
      )
      audit_log = create_action_log!(
        action_type: "LEDGER_COMPENSATION_REQUESTED",
        success: true,
        target_id: compensation_txn_id,
        metadata: base_metadata
      )
      compensation_metadata = base_metadata.deep_dup
      compensation_metadata["compensation"]["audit_action_log_id"] = audit_log.id

      entries = original_entries.map do |entry|
        {
          account_code: entry.account_code,
          entry_side: opposite_side(entry.entry_side),
          amount: entry.amount.to_d,
          party_id: entry.party_id,
          metadata: compensation_metadata.merge("original_entry_id" => entry.id)
        }
      end

      result = PostTransaction.new(
        tenant_id: @tenant_id,
        request_id: @request_id,
        actor_party_id: @actor_party_id,
        actor_role: @channel
      ).call(
        txn_id: compensation_txn_id,
        receivable_id: original_entries.first.receivable_id,
        payment_reference: compensation_payment_reference(compensation_reference),
        posted_at: posted_at,
        source_type: source_type,
        source_id: source_id,
        entries: entries
      )
      create_action_log!(
        action_type: "LEDGER_COMPENSATION_POSTED",
        success: true,
        target_id: compensation_txn_id,
        metadata: compensation_metadata
      )

      result
    rescue StandardError => error
      create_action_log_safely!(
        action_type: "LEDGER_COMPENSATION_FAILED",
        success: false,
        target_id: compensation_txn_id,
        metadata: {
          compensation: {
            original_txn_id: original_txn_id.to_s,
            compensation_reference: compensation_reference.to_s
          },
          error_class: error.class.name,
          error_message: error.message
        }
      )
      raise
    end

    private

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

    def create_action_log!(action_type:, success:, target_id:, metadata:)
      ActionIpLog.create!(
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
      )
    rescue ActiveRecord::RecordInvalid => error
      raise AuditLogError.new(
        code: "audit_log_write_failed",
        message: "failed to create action log #{action_type}: #{error.record.errors.full_messages.join(', ')}"
      )
    rescue ActiveRecord::ActiveRecordError => error
      raise AuditLogError.new(
        code: "audit_log_write_failed",
        message: "failed to create action log #{action_type}: #{error.message}"
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
