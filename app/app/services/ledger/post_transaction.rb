require "digest"
require "json"

module Ledger
  class PostTransaction
    IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY = "_txn_payload_hash".freeze
    IDEMPOTENCY_IGNORED_METADATA_PATHS = [
      %w[compensation audit_action_log_id]
    ].freeze

    class ValidationError < StandardError
      attr_reader :code

      def initialize(code:, message:)
        super(message)
        @code = code
      end
    end

    class IdempotencyConflict < ValidationError; end
    CallInputs = Struct.new(
      :txn_id,
      :posted_at,
      :source_type,
      :source_id,
      :entries,
      :receivable_id,
      :payment_reference,
      :payload_hash,
      keyword_init: true
    )
    SourceReference = Struct.new(:source_type, :source_id, :receivable_id, :payment_reference, keyword_init: true)

    def initialize(tenant_id:, request_id:, actor_party_id: nil, actor_role: nil)
      @tenant_id = tenant_id
      @request_id = request_id
      @actor_party_id = actor_party_id
      @actor_role = actor_role
    end

    def call(txn_id:, posted_at:, source_type:, source_id:, entries:, receivable_id: nil, payment_reference: nil)
      inputs = build_call_inputs(
        txn_id: txn_id,
        posted_at: posted_at,
        source_type: source_type,
        source_id: source_id,
        entries: entries,
        receivable_id: receivable_id,
        payment_reference: payment_reference
      )

      with_locked_transaction(txn_id: inputs.txn_id) { create_or_replay_locked(inputs) }
    rescue ActiveRecord::RecordNotUnique
      recover_after_unique_violation!(
        txn_id: inputs.txn_id,
        payload_hash: inputs.payload_hash,
        source_reference: source_reference_from_inputs(inputs)
      )
    end

    private

    def build_call_inputs(txn_id:, posted_at:, source_type:, source_id:, entries:, receivable_id:, payment_reference:)
      validate_entries!(entries)
      source_reference = build_source_reference(
        source_type: source_type,
        source_id: source_id,
        receivable_id: receivable_id,
        payment_reference: payment_reference
      )
      validate_reconciliation_reference!(
        source_type: source_reference.source_type,
        payment_reference: source_reference.payment_reference
      )
      payload_hash = idempotency_payload_hash(
        source_reference: source_reference,
        entries: entries
      )

      CallInputs.new(
        txn_id: txn_id,
        posted_at: posted_at,
        source_type: source_type,
        source_id: source_id,
        entries: entries,
        receivable_id: receivable_id,
        payment_reference: payment_reference,
        payload_hash: payload_hash
      )
    end

    def create_or_replay_locked(inputs)
      existing_txn = find_locked_transaction_by_txn_id(inputs.txn_id)
      return replay_existing_transaction!(
        ledger_transaction: existing_txn,
        payload_hash: inputs.payload_hash,
        source_reference: source_reference_from_inputs(inputs)
      ) if existing_txn

      create_transaction_entries!(inputs)
    end

    def create_transaction_entries!(inputs)
      ledger_transaction = create_ledger_transaction!(
        txn_id: inputs.txn_id,
        source_type: inputs.source_type,
        source_id: inputs.source_id,
        receivable_id: inputs.receivable_id,
        payment_reference: inputs.payment_reference,
        payload_hash: inputs.payload_hash,
        posted_at: inputs.posted_at,
        total_entries: inputs.entries.size
      )
      insert_ledger_entries!(
        entries: inputs.entries,
        txn_id: inputs.txn_id,
        source_type: inputs.source_type,
        source_id: inputs.source_id,
        receivable_id: inputs.receivable_id,
        payment_reference: inputs.payment_reference,
        payload_hash: inputs.payload_hash,
        posted_at: inputs.posted_at
      )

      fetch_entries!(ledger_transaction)
    end

    def with_locked_transaction(txn_id:)
      ActiveRecord::Base.transaction do
        lock_txn_id!(txn_id)
        yield
      end
    end

    def find_locked_transaction_by_txn_id(txn_id)
      LedgerTransaction.lock.find_by(tenant_id: @tenant_id, txn_id: txn_id)
    end

    def create_ledger_transaction!(txn_id:, source_type:, source_id:, receivable_id:, payment_reference:, payload_hash:, posted_at:, total_entries:)
      LedgerTransaction.create!(
        tenant_id: @tenant_id,
        txn_id: txn_id,
        source_type: source_type,
        source_id: source_id,
        receivable_id: receivable_id,
        payment_reference: payment_reference,
        actor_party_id: @actor_party_id,
        actor_role: @actor_role,
        request_id: @request_id,
        payload_hash: payload_hash,
        entry_count: total_entries,
        posted_at: posted_at,
        metadata: {}
      )
    end

    def source_reference_from_inputs(inputs)
      build_source_reference(
        source_type: inputs.source_type,
        source_id: inputs.source_id,
        receivable_id: inputs.receivable_id,
        payment_reference: inputs.payment_reference
      )
    end

    def build_source_reference(source_type:, source_id:, receivable_id:, payment_reference:)
      SourceReference.new(
        source_type: source_type,
        source_id: source_id,
        receivable_id: receivable_id,
        payment_reference: payment_reference
      )
    end

    def insert_ledger_entries!(entries:, txn_id:, source_type:, source_id:, receivable_id:, payment_reference:, payload_hash:, posted_at:)
      LedgerEntry.insert_all!(
        build_ledger_entry_rows(
          entries: entries,
          txn_id: txn_id,
          source_type: source_type,
          source_id: source_id,
          receivable_id: receivable_id,
          payment_reference: payment_reference,
          payload_hash: payload_hash,
          posted_at: posted_at
        )
      )
    end

    def build_ledger_entry_rows(entries:, txn_id:, source_type:, source_id:, receivable_id:, payment_reference:, payload_hash:, posted_at:)
      now = Time.current
      total_entries = entries.size

      entries.each_with_index.map do |entry, index|
        {
          id: SecureRandom.uuid,
          tenant_id: @tenant_id,
          txn_id: txn_id,
          entry_position: index + 1,
          txn_entry_count: total_entries,
          receivable_id: receivable_id,
          account_code: entry[:account_code],
          entry_side: entry[:entry_side],
          amount: round_money(entry[:amount]),
          currency: "BRL",
          party_id: entry[:party_id],
          payment_reference: payment_reference,
          source_type: source_type,
          source_id: source_id,
          metadata: build_entry_metadata(entry[:metadata], payload_hash: payload_hash),
          posted_at: posted_at,
          created_at: now,
          updated_at: now
        }
      end
    end

    def validate_reconciliation_reference!(source_type:, payment_reference:)
      return unless source_type.to_s == "ReceivablePaymentSettlement"
      return if payment_reference.to_s.strip.present?

      raise_validation_error!(
        "payment_reference_required",
        "payment_reference is required for ReceivablePaymentSettlement ledger postings."
      )
    end

    def validate_entries!(entries)
      raise_validation_error!("empty_entries", "entries must not be empty.") if entries.blank?
      validate_entry_shape!(entries)
      ensure_balanced_entries!(entries)
    end

    def validate_entry_shape!(entries)
      entries.each do |entry|
        validate_account_code!(entry[:account_code])
        validate_entry_side!(entry[:entry_side])
      end
    end

    def validate_account_code!(account_code)
      return if ChartOfAccounts.valid_code?(account_code)

      raise_validation_error!("unknown_account_code", "unknown account code: #{account_code}")
    end

    def validate_entry_side!(entry_side)
      return if %w[DEBIT CREDIT].include?(entry_side)

      raise_validation_error!("invalid_entry_side", "entry_side must be DEBIT or CREDIT.")
    end

    def ensure_balanced_entries!(entries)
      debit_sum, credit_sum = balance_totals(entries)

      return if debit_sum == credit_sum

      raise_validation_error!(
        "unbalanced_transaction",
        "transaction is unbalanced: debits=#{debit_sum.to_s('F')} credits=#{credit_sum.to_s('F')}"
      )
    end

    def balance_totals(entries)
      entries.each_with_object([ BigDecimal("0"), BigDecimal("0") ]) do |entry, totals|
        rounded_amount = round_money(entry[:amount])
        if entry[:entry_side] == "DEBIT"
          totals[0] += rounded_amount
        else
          totals[1] += rounded_amount
        end
      end
    end

    def round_money(value)
      FinancialRounding.money(value)
    end

    def lock_txn_id!(txn_id)
      connection = ActiveRecord::Base.connection
      tenant_key = connection.quote(@tenant_id.to_s)
      txn_key = connection.quote(txn_id.to_s)

      connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{tenant_key}), hashtext(#{txn_key}))")
    end

    def replay_existing_transaction!(
      ledger_transaction:,
      payload_hash:,
      source_reference:
    )
      ensure_matching_transaction!(
        ledger_transaction: ledger_transaction,
        payload_hash: payload_hash,
        source_reference: source_reference,
        conflict_code: "txn_id_reused_with_different_payload",
        conflict_message: "txn_id was already used with a different payload."
      )

      fetch_entries!(ledger_transaction)
    end

    def recover_after_unique_violation!(
      txn_id:,
      payload_hash:,
      source_reference:
    )
      ActiveRecord::Base.transaction do
        replayed = replay_for_existing_txn_after_race!(
          txn_id: txn_id,
          payload_hash: payload_hash,
          source_reference: source_reference
        )
        return replayed if replayed

        replayed_source = replay_for_source_collision_after_race!(
          payload_hash: payload_hash,
          source_reference: source_reference
        )
        return replayed_source if replayed_source
      end

      raise
    end

    def replay_for_existing_txn_after_race!(txn_id:, payload_hash:, source_reference:)
      ledger_transaction = LedgerTransaction.lock.find_by(tenant_id: @tenant_id, txn_id: txn_id)
      return nil if ledger_transaction.blank?

      replay_existing_transaction!(
        ledger_transaction: ledger_transaction,
        payload_hash: payload_hash,
        source_reference: source_reference
      )
    end

    def replay_for_source_collision_after_race!(payload_hash:, source_reference:)
      source_collision = LedgerTransaction.lock.find_by(
        tenant_id: @tenant_id,
        source_type: source_reference.source_type,
        source_id: source_reference.source_id
      )
      return nil if source_collision.blank?

      ensure_matching_transaction!(
        ledger_transaction: source_collision,
        payload_hash: payload_hash,
        source_reference: source_reference,
        conflict_code: "source_reused_with_different_payload",
        conflict_message: "source_type/source_id was already posted with a different payload."
      )
      fetch_entries!(source_collision)
    end

    def fetch_entries!(ledger_transaction)
      records = LedgerEntry.where(tenant_id: @tenant_id, txn_id: ledger_transaction.txn_id).order(:entry_position, :created_at).to_a
      if records.size != ledger_transaction.entry_count
        raise_validation_error!(
          "incomplete_transaction_replay",
          "existing transaction is incomplete: entries=#{records.size} expected=#{ledger_transaction.entry_count}"
        )
      end

      records
    end

    def ensure_matching_transaction!(
      ledger_transaction:,
      payload_hash:,
      source_reference:,
      conflict_code:,
      conflict_message:
    )
      source_matches = transaction_source_matches?(
        ledger_transaction: ledger_transaction,
        source_reference: source_reference
      )
      stored_hash = stored_transaction_hash(ledger_transaction)
      return if source_matches && stored_hash == payload_hash

      raise_idempotency_conflict!(
        conflict_code,
        conflict_message
      )
    end

    def transaction_source_matches?(ledger_transaction:, source_reference:)
      ledger_transaction.source_type.to_s == source_reference.source_type.to_s &&
        ledger_transaction.source_id.to_s == source_reference.source_id.to_s &&
        ledger_transaction.receivable_id.to_s == source_reference.receivable_id.to_s &&
        ledger_transaction.payment_reference.to_s == source_reference.payment_reference.to_s
    end

    def stored_transaction_hash(ledger_transaction)
      return ledger_transaction.payload_hash if ledger_transaction.payload_hash.present?
      return ledger_transaction.metadata[IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY] if ledger_transaction.metadata.is_a?(Hash) && ledger_transaction.metadata[IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY].present?

      existing = LedgerEntry.where(tenant_id: @tenant_id, txn_id: ledger_transaction.txn_id).order(:entry_position, :created_at).to_a
      metadata_hashes = entry_payload_hashes(existing)
      return metadata_hashes.first if metadata_hashes.one?
      return idempotency_payload_hash_from_records(existing) if metadata_hashes.empty?

      raise_idempotency_conflict!(
        "inconsistent_txn_payload_hash",
        "existing txn_id has inconsistent payload hashes."
      )
    end

    def entry_payload_hashes(entries)
      entries.filter_map do |entry|
        metadata = entry.metadata
        next unless metadata.is_a?(Hash)

        value = metadata[IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY] || metadata[IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY.to_sym]
        value.to_s.presence
      end.uniq
    end

    def idempotency_payload_hash(source_reference:, entries:)
      payload = canonicalize_json(
        idempotency_hash_payload(
          source_reference: source_reference,
          entries_payload: normalized_entries_for_payload(entries)
        )
      )
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def idempotency_payload_hash_from_records(existing)
      reference = existing.first
      return "" if reference.blank?

      source_reference = build_source_reference(
        source_type: reference.source_type,
        source_id: reference.source_id,
        receivable_id: reference.receivable_id,
        payment_reference: reference.payment_reference
      )
      payload = canonicalize_json(
        idempotency_hash_payload(
          source_reference: source_reference,
          entries_payload: normalized_existing_entries_for_payload(existing)
        )
      )
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def idempotency_hash_payload(source_reference:, entries_payload:)
      {
        "source_type" => source_reference.source_type.to_s,
        "source_id" => source_reference.source_id.to_s,
        "receivable_id" => source_reference.receivable_id&.to_s,
        "payment_reference" => source_reference.payment_reference&.to_s,
        "entries" => entries_payload
      }
    end

    def normalized_entries_for_payload(entries)
      sort_entries_for_payload(entries.map { |entry| normalized_entry_payload(entry) })
    end

    def normalized_existing_entries_for_payload(records)
      sort_entries_for_payload(records.map { |entry| normalized_existing_entry_payload(entry) })
    end

    def normalized_entry_payload(entry)
      metadata = metadata_for_idempotency(normalize_entry_metadata(entry[:metadata]))
      {
        "account_code" => entry[:account_code].to_s,
        "entry_side" => entry[:entry_side].to_s,
        "amount" => round_money(entry[:amount]).to_s("F"),
        "party_id" => entry[:party_id]&.to_s,
        "metadata" => metadata
      }
    end

    def normalized_existing_entry_payload(entry)
      metadata = metadata_for_idempotency(normalize_entry_metadata(entry.metadata))
      {
        "account_code" => entry.account_code.to_s,
        "entry_side" => entry.entry_side.to_s,
        "amount" => entry.amount.to_d.to_s("F"),
        "party_id" => entry.party_id&.to_s,
        "metadata" => metadata
      }
    end

    def sort_entries_for_payload(entries)
      entries.sort_by do |entry|
        [ entry["account_code"], entry["entry_side"], entry["amount"], entry["party_id"].to_s, JSON.generate(entry["metadata"]) ]
      end
    end

    def build_entry_metadata(raw_metadata, payload_hash:)
      strip_internal_metadata(normalize_entry_metadata(raw_metadata)).merge(
        IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY => payload_hash
      )
    end

    def metadata_for_idempotency(metadata)
      normalized = strip_internal_metadata(metadata)
      remove_ignored_metadata_paths(normalized)
    end

    def strip_internal_metadata(metadata)
      metadata.except(IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY)
    end

    def remove_ignored_metadata_paths(metadata)
      sanitized = metadata.deep_dup
      IDEMPOTENCY_IGNORED_METADATA_PATHS.each do |path|
        remove_nested_key!(sanitized, path)
      end
      sanitized
    end

    def remove_nested_key!(value, path)
      return if path.empty?
      return unless value.is_a?(Hash)

      key = path.first
      return unless value.key?(key)
      return value.delete(key) if path.size == 1

      child = value[key]
      remove_nested_key!(child, path.drop(1))
      value.delete(key) if child.is_a?(Hash) && child.empty?
    end

    def normalize_entry_metadata(value)
      return {} if value.nil?
      return canonicalize_json(value.deep_stringify_keys) if value.is_a?(Hash)

      raise_validation_error!("invalid_entry_metadata", "entry metadata must be an object.")
    end

    def canonicalize_json(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, hash|
          source_key = value.key?(key) ? key : key.to_sym
          hash[key] = canonicalize_json(value[source_key])
        end
      when Array
        value.map { |item| canonicalize_json(item) }
      else
        value
      end
    end

    def raise_idempotency_conflict!(code, message)
      raise IdempotencyConflict.new(code:, message:)
    end

    def raise_validation_error!(code, message)
      raise ValidationError.new(code:, message:)
    end
  end
end
