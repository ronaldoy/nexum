class ScopeDirectUploadIdempotencyToActor < ActiveRecord::Migration[8.2]
  INDEX_NAME = "index_active_storage_blobs_on_tenant_direct_upload_idempotency".freeze

  def up
    ensure_active_storage_blob_helper_functions!

    execute <<~SQL
      DROP INDEX IF EXISTS #{INDEX_NAME};
    SQL

    execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS #{INDEX_NAME}
      ON active_storage_blobs (
        public.app_active_storage_blob_tenant_id(metadata::text),
        (public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_actor_key'),
        (public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_idempotency_key')
      )
      WHERE
        public.app_active_storage_blob_tenant_id(metadata::text) IS NOT NULL
        AND COALESCE(public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_actor_key', '') <> ''
        AND COALESCE(public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_idempotency_key', '') <> '';
    SQL
  end

  def down
    ensure_active_storage_blob_helper_functions!

    execute <<~SQL
      DROP INDEX IF EXISTS #{INDEX_NAME};
    SQL

    execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS #{INDEX_NAME}
      ON active_storage_blobs (
        public.app_active_storage_blob_tenant_id(metadata::text),
        (public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_idempotency_key')
      )
      WHERE
        public.app_active_storage_blob_tenant_id(metadata::text) IS NOT NULL
        AND COALESCE(public.app_active_storage_blob_metadata_json(metadata::text) ->> 'direct_upload_idempotency_key', '') <> '';
    SQL
  end

  private

  def ensure_active_storage_blob_helper_functions!
    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.app_active_storage_blob_metadata_json(blob_metadata text)
      RETURNS jsonb
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      BEGIN
        IF blob_metadata IS NULL OR btrim(blob_metadata) = '' THEN
          RETURN '{}'::jsonb;
        END IF;

        BEGIN
          RETURN blob_metadata::jsonb;
        EXCEPTION
          WHEN invalid_text_representation THEN
            RETURN '{}'::jsonb;
        END;
      END;
      $$;
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION public.app_active_storage_blob_tenant_id(blob_metadata text)
      RETURNS uuid
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      DECLARE
        tenant_raw text;
      BEGIN
        tenant_raw := NULLIF(public.app_active_storage_blob_metadata_json(blob_metadata)->>'tenant_id', '');
        IF tenant_raw IS NULL THEN
          RETURN NULL;
        END IF;

        BEGIN
          RETURN tenant_raw::uuid;
        EXCEPTION
          WHEN invalid_text_representation THEN
            RETURN NULL;
        END;
      END;
      $$;
    SQL
  end
end
