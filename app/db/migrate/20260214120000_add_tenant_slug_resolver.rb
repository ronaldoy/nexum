class AddTenantSlugResolver < ActiveRecord::Migration[8.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_resolve_tenant_id_by_slug(slug text)
      RETURNS uuid
      LANGUAGE sql
      STABLE
      SECURITY DEFINER
      SET search_path = public
      AS $$
        SELECT id FROM tenants WHERE tenants.slug = app_resolve_tenant_id_by_slug.slug AND active = true LIMIT 1;
      $$;
    SQL
  end

  def down
    execute <<~SQL
      DROP FUNCTION IF EXISTS app_resolve_tenant_id_by_slug(text);
    SQL
  end
end
