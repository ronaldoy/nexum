class AddDirectUploadIdempotencyIndexToActiveStorageBlobs < ActiveRecord::Migration[8.2]
  INDEX_NAME = "index_active_storage_blobs_on_tenant_direct_upload_idempotency".freeze

  def up
    execute <<~SQL
      CREATE UNIQUE INDEX IF NOT EXISTS #{INDEX_NAME}
      ON active_storage_blobs (
        app_active_storage_blob_tenant_id(metadata),
        (app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key')
      )
      WHERE
        app_active_storage_blob_tenant_id(metadata) IS NOT NULL
        AND COALESCE(app_active_storage_blob_metadata_json(metadata) ->> 'direct_upload_idempotency_key', '') <> '';
    SQL
  end

  def down
    execute <<~SQL
      DROP INDEX IF EXISTS #{INDEX_NAME};
    SQL
  end
end
