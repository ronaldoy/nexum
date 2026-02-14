class HardenActiveStorageTenantIsolation < ActiveRecord::Migration[8.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_active_storage_blob_metadata_json(blob_metadata text)
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
      CREATE OR REPLACE FUNCTION app_active_storage_blob_tenant_id(blob_metadata text)
      RETURNS uuid
      LANGUAGE plpgsql
      IMMUTABLE
      AS $$
      DECLARE
        tenant_raw text;
      BEGIN
        tenant_raw := NULLIF(app_active_storage_blob_metadata_json(blob_metadata)->>'tenant_id', '');
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

    execute <<~SQL
      UPDATE active_storage_blobs AS blobs
      SET metadata = jsonb_set(
        app_active_storage_blob_metadata_json(blobs.metadata),
        '{tenant_id}',
        to_jsonb(source.tenant_id::text),
        true
      )::text
      FROM (
        SELECT DISTINCT
          attachments.blob_id,
          COALESCE(documents.tenant_id, kyc_documents.tenant_id) AS tenant_id
        FROM active_storage_attachments AS attachments
        LEFT JOIN documents
          ON attachments.record_type = 'Document'
         AND attachments.record_id = documents.id::text
        LEFT JOIN kyc_documents
          ON attachments.record_type = 'KycDocument'
         AND attachments.record_id = kyc_documents.id::text
        WHERE COALESCE(documents.tenant_id, kyc_documents.tenant_id) IS NOT NULL
      ) AS source
      WHERE blobs.id = source.blob_id
        AND app_active_storage_blob_tenant_id(blobs.metadata) IS NULL;
    SQL

    execute <<~SQL
      ALTER TABLE active_storage_blobs ENABLE ROW LEVEL SECURITY;
      ALTER TABLE active_storage_blobs FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS active_storage_blobs_tenant_policy ON active_storage_blobs;
      CREATE POLICY active_storage_blobs_tenant_policy
      ON active_storage_blobs
      USING (app_active_storage_blob_tenant_id(metadata) = app_current_tenant_id())
      WITH CHECK (app_active_storage_blob_tenant_id(metadata) = app_current_tenant_id());
    SQL

    execute <<~SQL
      ALTER TABLE active_storage_attachments ENABLE ROW LEVEL SECURITY;
      ALTER TABLE active_storage_attachments FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS active_storage_attachments_tenant_policy ON active_storage_attachments;
      CREATE POLICY active_storage_attachments_tenant_policy
      ON active_storage_attachments
      USING (
        EXISTS (
          SELECT 1
          FROM active_storage_blobs blobs
          WHERE blobs.id = active_storage_attachments.blob_id
            AND app_active_storage_blob_tenant_id(blobs.metadata) = app_current_tenant_id()
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM active_storage_blobs blobs
          WHERE blobs.id = active_storage_attachments.blob_id
            AND app_active_storage_blob_tenant_id(blobs.metadata) = app_current_tenant_id()
        )
      );
    SQL

    execute <<~SQL
      ALTER TABLE active_storage_variant_records ENABLE ROW LEVEL SECURITY;
      ALTER TABLE active_storage_variant_records FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS active_storage_variant_records_tenant_policy ON active_storage_variant_records;
      CREATE POLICY active_storage_variant_records_tenant_policy
      ON active_storage_variant_records
      USING (
        EXISTS (
          SELECT 1
          FROM active_storage_blobs blobs
          WHERE blobs.id = active_storage_variant_records.blob_id
            AND app_active_storage_blob_tenant_id(blobs.metadata) = app_current_tenant_id()
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1
          FROM active_storage_blobs blobs
          WHERE blobs.id = active_storage_variant_records.blob_id
            AND app_active_storage_blob_tenant_id(blobs.metadata) = app_current_tenant_id()
        )
      );
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Active Storage tenant isolation hardening cannot be safely reverted."
  end
end
