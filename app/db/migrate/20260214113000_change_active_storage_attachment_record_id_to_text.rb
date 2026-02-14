class ChangeActiveStorageAttachmentRecordIdToText < ActiveRecord::Migration[8.2]
  INDEX_NAME = :index_active_storage_attachments_uniqueness

  def up
    remove_index :active_storage_attachments, name: INDEX_NAME if index_exists?(:active_storage_attachments, name: INDEX_NAME)
    change_column :active_storage_attachments, :record_id, :text, null: false
    add_index :active_storage_attachments, %i[record_type record_id name blob_id], name: INDEX_NAME, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "record_id cannot be safely converted back to bigint once UUID records exist"
  end
end
