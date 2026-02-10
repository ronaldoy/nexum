class EncryptPiiAtRest < ActiveRecord::Migration[8.2]
  class UserRecord < ActiveRecord::Base
    self.table_name = "users"
    encrypts :email_address, deterministic: true
  end

  class PartyRecord < ActiveRecord::Base
    self.table_name = "parties"
    encrypts :document_number, deterministic: true
    encrypts :legal_name
    encrypts :display_name
  end

  class PhysicianRecord < ActiveRecord::Base
    self.table_name = "physicians"
    encrypts :full_name
    encrypts :email, deterministic: true
    encrypts :phone
  end

  class KycDocumentRecord < ActiveRecord::Base
    self.table_name = "kyc_documents"
    encrypts :document_number
  end

  def up
    remove_parties_document_index!
    change_pii_column_types!
    restore_parties_document_index!
    encrypt_existing_pii!
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "PII encryption migration cannot be safely reversed."
  end

  private

  def remove_parties_document_index!
    return unless index_exists?(:parties, %i[tenant_id kind document_number], name: "index_parties_on_tenant_kind_document")

    remove_index :parties, name: "index_parties_on_tenant_kind_document"
  end

  def change_pii_column_types!
    change_column :users, :email_address, :text

    change_column :parties, :document_number, :text
    change_column :parties, :legal_name, :text
    change_column :parties, :display_name, :text

    change_column :physicians, :full_name, :text
    change_column :physicians, :email, :text
    change_column :physicians, :phone, :text

    change_column :kyc_documents, :document_number, :text
  end

  def restore_parties_document_index!
    add_index :parties,
      %i[tenant_id kind document_number],
      unique: true,
      where: "document_number IS NOT NULL",
      name: "index_parties_on_tenant_kind_document"
  end

  def encrypt_existing_pii!
    encrypt_records(UserRecord)
    encrypt_records(PartyRecord)
    encrypt_records(PhysicianRecord)
    encrypt_records(KycDocumentRecord)
  end

  def encrypt_records(model_class)
    model_class.in_batches(of: 500) do |relation|
      relation.each do |record|
        record.encrypt
        record.save!(validate: false, touch: false)
      end
    end
  end
end
