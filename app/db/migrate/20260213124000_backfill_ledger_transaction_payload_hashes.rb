require "digest"
require "json"

class BackfillLedgerTransactionPayloadHashes < ActiveRecord::Migration[8.2]
  IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY = "_txn_payload_hash".freeze
  IDEMPOTENCY_IGNORED_METADATA_PATHS = [
    %w[compensation audit_action_log_id]
  ].freeze

  def up
    backfill_payload_hashes!

    change_column_null :ledger_transactions, :payload_hash, false
    add_check_constraint :ledger_transactions,
      "btrim(payload_hash) <> ''",
      name: "ledger_transactions_payload_hash_present_check"
  end

  def down
    remove_check_constraint :ledger_transactions, name: "ledger_transactions_payload_hash_present_check"
    change_column_null :ledger_transactions, :payload_hash, true
  end

  private

  def backfill_payload_hashes!
    connection = ActiveRecord::Base.connection
    rows = connection.select_all(<<~SQL)
      SELECT tenant_id, txn_id
      FROM ledger_transactions
      WHERE payload_hash IS NULL OR btrim(payload_hash) = ''
      ORDER BY created_at, id
    SQL

    rows.each do |row|
      tenant_id = row.fetch("tenant_id")
      txn_id = row.fetch("txn_id")
      entries = connection.select_all(<<~SQL)
        SELECT
          account_code,
          entry_side,
          amount,
          party_id,
          metadata,
          source_type,
          source_id,
          receivable_id,
          payment_reference
        FROM ledger_entries
        WHERE tenant_id = #{connection.quote(tenant_id)}
          AND txn_id = #{connection.quote(txn_id)}
        ORDER BY entry_position, created_at, id
      SQL

      raise "cannot backfill payload_hash without ledger entries for txn_id=#{txn_id}" if entries.empty?

      payload_hash = idempotency_payload_hash_from_entries(entries)
      connection.execute(<<~SQL)
        UPDATE ledger_transactions
        SET payload_hash = #{connection.quote(payload_hash)}
        WHERE tenant_id = #{connection.quote(tenant_id)}
          AND txn_id = #{connection.quote(txn_id)}
      SQL
    end
  end

  def idempotency_payload_hash_from_entries(entries)
    reference = entries.first
    payload = canonicalize_json(
      {
        "source_type" => reference["source_type"].to_s,
        "source_id" => reference["source_id"]&.to_s,
        "receivable_id" => reference["receivable_id"]&.to_s,
        "payment_reference" => reference["payment_reference"]&.to_s,
        "entries" => sort_entries_for_payload(entries.map { |entry| normalized_entry_payload(entry) })
      }
    )

    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  def normalized_entry_payload(entry)
    metadata = metadata_for_idempotency(normalize_entry_metadata(entry["metadata"]))
    {
      "account_code" => entry["account_code"].to_s,
      "entry_side" => entry["entry_side"].to_s,
      "amount" => BigDecimal(entry["amount"].to_s).to_s("F"),
      "party_id" => entry["party_id"]&.to_s,
      "metadata" => metadata
    }
  end

  def sort_entries_for_payload(entries)
    entries.sort_by do |entry|
      [
        entry["account_code"],
        entry["entry_side"],
        entry["amount"],
        entry["party_id"].to_s,
        JSON.generate(entry["metadata"])
      ]
    end
  end

  def normalize_entry_metadata(value)
    parsed = parse_metadata(value)
    canonicalize_json(stringify_keys(parsed))
  end

  def parse_metadata(value)
    return {} if value.nil?
    return value if value.is_a?(Hash)

    JSON.parse(value.to_s)
  rescue JSON::ParserError
    {}
  end

  def stringify_keys(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), hash|
        hash[key.to_s] = stringify_keys(child)
      end
    when Array
      value.map { |child| stringify_keys(child) }
    else
      value
    end
  end

  def metadata_for_idempotency(metadata)
    normalized = strip_internal_metadata(metadata)
    remove_ignored_metadata_paths(normalized)
  end

  def strip_internal_metadata(metadata)
    metadata.each_with_object({}) do |(key, value), hash|
      hash[key] = value unless key.to_s == IDEMPOTENCY_PAYLOAD_HASH_METADATA_KEY
    end
  end

  def remove_ignored_metadata_paths(metadata)
    sanitized = Marshal.load(Marshal.dump(metadata))
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
end
