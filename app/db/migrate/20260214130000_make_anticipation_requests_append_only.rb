class MakeAnticipationRequestsAppendOnly < ActiveRecord::Migration[8.2]
  def up
    # 1. Create anticipation_request_events table
    create_table :anticipation_request_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :tenant_id, null: false
      t.uuid :anticipation_request_id, null: false
      t.integer :sequence, null: false
      t.string :event_type, null: false
      t.string :status_before
      t.string :status_after
      t.uuid :actor_party_id
      t.string :actor_role
      t.string :request_id
      t.datetime :occurred_at, null: false
      t.string :prev_hash
      t.string :event_hash, null: false
      t.jsonb :payload, default: {}
      t.timestamps
    end

    add_index :anticipation_request_events,
              [ :tenant_id, :anticipation_request_id, :sequence ],
              unique: true,
              name: "idx_anticipation_request_events_unique_seq"

    add_index :anticipation_request_events, :tenant_id
    add_index :anticipation_request_events, :anticipation_request_id

    # Append-only trigger on anticipation_request_events
    execute <<~SQL
      CREATE TRIGGER anticipation_request_events_no_update_delete
        BEFORE UPDATE OR DELETE ON anticipation_request_events
        FOR EACH ROW EXECUTE FUNCTION app_forbid_mutation();
    SQL

    # RLS on anticipation_request_events
    execute <<~SQL
      ALTER TABLE anticipation_request_events ENABLE ROW LEVEL SECURITY;
      ALTER TABLE anticipation_request_events FORCE ROW LEVEL SECURITY;

      CREATE POLICY anticipation_request_events_tenant_policy
        ON anticipation_request_events
        USING (tenant_id = app_current_tenant_id())
        WITH CHECK (tenant_id = app_current_tenant_id());
    SQL

    # 2. Create protection function for anticipation_requests
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_protect_anticipation_requests()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'DELETE not allowed on anticipation_requests';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF current_setting('app.allow_anticipation_status_transition', true) = 'true' THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'UPDATE not allowed on anticipation_requests without status transition gate';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL

    # 3. Create trigger on anticipation_requests
    execute <<~SQL
      CREATE TRIGGER anticipation_requests_protect_mutation
        BEFORE UPDATE OR DELETE ON anticipation_requests
        FOR EACH ROW EXECUTE FUNCTION app_protect_anticipation_requests();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS anticipation_requests_protect_mutation ON anticipation_requests;
      DROP FUNCTION IF EXISTS app_protect_anticipation_requests();
    SQL

    execute <<~SQL
      DROP POLICY IF EXISTS anticipation_request_events_tenant_policy ON anticipation_request_events;
      DROP TRIGGER IF EXISTS anticipation_request_events_no_update_delete ON anticipation_request_events;
    SQL

    drop_table :anticipation_request_events
  end
end
