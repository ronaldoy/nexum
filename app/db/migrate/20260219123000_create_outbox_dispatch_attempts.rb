class CreateOutboxDispatchAttempts < ActiveRecord::Migration[8.2]
  DISPATCH_STATUSES = %w[SENT RETRY_SCHEDULED DEAD_LETTER].freeze

  def up
    create_table :outbox_dispatch_attempts, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :outbox_event, null: false, type: :uuid, foreign_key: true
      t.integer :attempt_number, null: false
      t.string :status, null: false
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :next_attempt_at
      t.string :error_code
      t.string :error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint(
      :outbox_dispatch_attempts,
      "attempt_number > 0",
      name: "outbox_dispatch_attempts_attempt_number_check"
    )
    add_check_constraint(
      :outbox_dispatch_attempts,
      "status IN ('#{DISPATCH_STATUSES.join("','")}')",
      name: "outbox_dispatch_attempts_status_check"
    )
    add_index(
      :outbox_dispatch_attempts,
      %i[tenant_id outbox_event_id attempt_number],
      unique: true,
      name: "index_outbox_dispatch_attempts_unique_attempt"
    )
    add_index(
      :outbox_dispatch_attempts,
      %i[tenant_id status next_attempt_at],
      name: "index_outbox_dispatch_attempts_retry_scan"
    )
    add_index(
      :outbox_dispatch_attempts,
      %i[tenant_id outbox_event_id occurred_at],
      name: "index_outbox_dispatch_attempts_lookup"
    )

    enable_tenant_rls("outbox_dispatch_attempts")
    create_append_only_trigger("outbox_dispatch_attempts")
  end

  def down
    drop_table :outbox_dispatch_attempts
  end

  private

  def enable_tenant_rls(table_name)
    execute <<~SQL
      ALTER TABLE #{table_name} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table_name} FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS #{table_name}_tenant_policy ON #{table_name};
      CREATE POLICY #{table_name}_tenant_policy
      ON #{table_name}
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end

  def create_append_only_trigger(table_name)
    execute <<~SQL
      DROP TRIGGER IF EXISTS #{table_name}_no_update_delete ON #{table_name};
      CREATE TRIGGER #{table_name}_no_update_delete
      BEFORE UPDATE OR DELETE ON #{table_name}
      FOR EACH ROW
      EXECUTE FUNCTION app_forbid_mutation();
    SQL
  end
end
