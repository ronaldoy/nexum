class HardenTenantSlugLookupRls < ActiveRecord::Migration[8.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_resolve_tenant_id_by_slug(slug text)
      RETURNS uuid
      LANGUAGE sql
      STABLE
      SECURITY INVOKER
      SET search_path = public
      AS $$
        SELECT id
        FROM tenants
        WHERE tenants.slug = app_resolve_tenant_id_by_slug.slug
          AND active = true
        LIMIT 1;
      $$;
    SQL

    execute <<~SQL
      DROP POLICY IF EXISTS tenants_slug_lookup_policy ON tenants;
      CREATE POLICY tenants_slug_lookup_policy
      ON tenants
      FOR SELECT
      USING (
        current_setting('app.allow_tenant_slug_lookup', true) = 'true'
        AND slug = NULLIF(current_setting('app.requested_tenant_slug', true), '')
        AND active = true
      );
    SQL
  end

  def down
    execute <<~SQL
      DROP POLICY IF EXISTS tenants_slug_lookup_policy ON tenants;
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_resolve_tenant_id_by_slug(slug text)
      RETURNS uuid
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = public
      AS $$
        SELECT id
        FROM tenants
        WHERE tenants.slug = app_resolve_tenant_id_by_slug.slug
          AND active = true
        LIMIT 1;
      $$;
    SQL
  end
end
