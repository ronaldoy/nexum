class AddDatabaseRequestContextFunction < ActiveRecord::Migration[8.2]
  def up
    execute "CREATE SCHEMA IF NOT EXISTS app"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION app.set_request_context(
        tenant_id text,
        actor_id text DEFAULT NULL,
        actor_role text DEFAULT NULL,
        request_id text DEFAULT NULL,
        is_local boolean DEFAULT true
      ) RETURNS void
          LANGUAGE plpgsql
          AS $$
      BEGIN
        PERFORM set_config('app.tenant_id', COALESCE(tenant_id, ''), is_local);
        PERFORM set_config('app.actor_id', COALESCE(actor_id, ''), is_local);
        PERFORM set_config('app.role', COALESCE(actor_role, ''), is_local);
        PERFORM set_config('app.request_id', COALESCE(request_id, ''), is_local);
      END;
      $$;
    SQL
  end

  def down
    execute "DROP FUNCTION IF EXISTS app.set_request_context(text, text, text, text, boolean)"
  end
end
