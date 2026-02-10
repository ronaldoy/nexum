class AddPartyDocumentTypeAndKycWorkflow < ActiveRecord::Migration[8.2]
  PARTY_DOCUMENT_TYPES = %w[CPF CNPJ].freeze
  KYC_PROFILE_STATUSES = %w[DRAFT PENDING_REVIEW NEEDS_INFORMATION APPROVED REJECTED].freeze
  KYC_RISK_LEVELS = %w[UNKNOWN LOW MEDIUM HIGH].freeze
  KYC_DOCUMENT_TYPES = %w[CPF CNPJ RG CNH PASSPORT PROOF_OF_ADDRESS SELFIE CONTRACT OTHER].freeze
  KYC_DOCUMENT_STATUSES = %w[SUBMITTED VERIFIED REJECTED EXPIRED].freeze
  BRAZILIAN_STATES = %w[
    AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO
  ].freeze

  def up
    add_column :parties, :document_type, :string
    execute <<~SQL
      UPDATE parties
      SET document_type = CASE
        WHEN kind = 'PHYSICIAN_PF' THEN 'CPF'
        ELSE 'CNPJ'
      END
      WHERE document_type IS NULL;
    SQL
    change_column_null :parties, :document_type, false
    add_check_constraint :parties, "document_type IN ('#{PARTY_DOCUMENT_TYPES.join("','")}')", name: "parties_document_type_check"
    add_check_constraint :parties,
      "((kind = 'PHYSICIAN_PF' AND document_type = 'CPF') OR (kind <> 'PHYSICIAN_PF' AND document_type = 'CNPJ'))",
      name: "parties_document_type_kind_check"

    create_table :kyc_profiles, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.string :status, null: false, default: "DRAFT"
      t.string :risk_level, null: false, default: "UNKNOWN"
      t.datetime :submitted_at
      t.datetime :reviewed_at
      t.references :reviewer_party, type: :uuid, foreign_key: { to_table: :parties }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :kyc_profiles, "status IN ('#{KYC_PROFILE_STATUSES.join("','")}')", name: "kyc_profiles_status_check"
    add_check_constraint :kyc_profiles, "risk_level IN ('#{KYC_RISK_LEVELS.join("','")}')", name: "kyc_profiles_risk_level_check"
    add_index :kyc_profiles, %i[tenant_id party_id], unique: true, name: "index_kyc_profiles_on_tenant_party"

    create_table :kyc_documents, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :kyc_profile, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.string :document_type, null: false
      t.string :document_number
      t.string :issuing_country, null: false, default: "BR"
      t.string :issuing_state, limit: 2
      t.date :issued_on
      t.date :expires_on
      t.boolean :is_key_document, null: false, default: false
      t.string :status, null: false, default: "SUBMITTED"
      t.datetime :verified_at
      t.string :rejection_reason
      t.string :storage_key, null: false
      t.string :sha256, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :kyc_documents, "document_type IN ('#{KYC_DOCUMENT_TYPES.join("','")}')", name: "kyc_documents_document_type_check"
    add_check_constraint :kyc_documents, "status IN ('#{KYC_DOCUMENT_STATUSES.join("','")}')", name: "kyc_documents_status_check"
    add_check_constraint :kyc_documents, "char_length(sha256) > 0", name: "kyc_documents_sha256_present_check"
    add_check_constraint :kyc_documents, "char_length(storage_key) > 0", name: "kyc_documents_storage_key_present_check"
    add_check_constraint :kyc_documents, "issuing_state IS NULL OR issuing_state IN ('#{BRAZILIAN_STATES.join("','")}')", name: "kyc_documents_issuing_state_check"
    add_check_constraint :kyc_documents, "(NOT is_key_document) OR document_type IN ('CPF','CNPJ')", name: "kyc_documents_key_document_type_check"
    add_check_constraint :kyc_documents, "(document_type NOT IN ('RG','CNH','PASSPORT')) OR (is_key_document = FALSE)", name: "kyc_documents_non_key_identity_docs_check"
    add_index :kyc_documents, %i[tenant_id party_id document_type status], name: "idx_kyc_documents_lookup"
    add_index :kyc_documents,
      %i[tenant_id party_id document_type],
      unique: true,
      where: "is_key_document = TRUE",
      name: "idx_kyc_documents_unique_key_per_type"

    create_table :kyc_events, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :kyc_profile, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.references :actor_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.string :request_id
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :kyc_events, %i[tenant_id kyc_profile_id occurred_at], name: "idx_kyc_events_tenant_profile_time"
    add_index :kyc_events, %i[tenant_id party_id occurred_at], name: "idx_kyc_events_tenant_party_time"

    create_append_only_trigger(:kyc_events)
    enable_tenant_rls(:kyc_profiles)
    enable_tenant_rls(:kyc_documents)
    enable_tenant_rls(:kyc_events)
  end

  def down
    execute "DROP POLICY IF EXISTS kyc_events_tenant_policy ON kyc_events;"
    execute "DROP POLICY IF EXISTS kyc_documents_tenant_policy ON kyc_documents;"
    execute "DROP POLICY IF EXISTS kyc_profiles_tenant_policy ON kyc_profiles;"
    execute "DROP TRIGGER IF EXISTS kyc_events_no_update_delete ON kyc_events;"

    drop_table :kyc_events
    drop_table :kyc_documents
    drop_table :kyc_profiles

    remove_check_constraint :parties, name: "parties_document_type_kind_check"
    remove_check_constraint :parties, name: "parties_document_type_check"
    remove_column :parties, :document_type
  end

  private

  def create_append_only_trigger(table_name)
    execute <<~SQL
      DROP TRIGGER IF EXISTS #{table_name}_no_update_delete ON #{table_name};
      CREATE TRIGGER #{table_name}_no_update_delete
      BEFORE UPDATE OR DELETE ON #{table_name}
      FOR EACH ROW
      EXECUTE FUNCTION app_forbid_mutation();
    SQL
  end

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
end
