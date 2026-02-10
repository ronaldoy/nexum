class CreateComposableReceivablesSchema < ActiveRecord::Migration[8.2]
  PARTY_KINDS = %w[HOSPITAL SUPPLIER PHYSICIAN_PF LEGAL_ENTITY_PJ FIDC PLATFORM].freeze
  MEMBERSHIP_ROLES = %w[ADMIN MEMBER].freeze
  MEMBERSHIP_STATUSES = %w[ACTIVE INACTIVE].freeze
  RECEIVABLE_FAMILIES = %w[PHYSICIAN SUPPLIER OTHER].freeze
  RECEIVABLE_STATUSES = %w[PERFORMED ANTICIPATION_REQUESTED FUNDED SETTLED CANCELLED].freeze
  ALLOCATION_STATUSES = %w[OPEN SETTLED CANCELLED].freeze
  ANTICIPATION_STATUSES = %w[REQUESTED APPROVED FUNDED SETTLED CANCELLED REJECTED].freeze
  REQUEST_CHANNELS = %w[API PORTAL WEBHOOK INTERNAL].freeze
  EVENTABLE_STATUSES = %w[PENDING SENT FAILED CANCELLED].freeze
  AUTH_CHALLENGE_STATUSES = %w[PENDING VERIFIED EXPIRED CANCELLED].freeze
  DELIVERY_CHANNELS = %w[EMAIL WHATSAPP].freeze
  METRIC_SCOPES = %w[GLOBAL DEBTOR CREDITOR BENEFICIARY].freeze
  LOG_CHANNELS = %w[API PORTAL WORKER WEBHOOK ADMIN].freeze

  SENSITIVE_TABLES = %w[
    parties
    physicians
    physician_legal_entity_memberships
    physician_anticipation_authorizations
    receivable_kinds
    receivables
    receivable_allocations
    anticipation_requests
    receivable_events
    documents
    document_events
    auth_challenges
    action_ip_logs
    outbox_events
    receivable_statistics_daily
  ].freeze

  APPEND_ONLY_TABLES = %w[
    receivable_events
    document_events
    action_ip_logs
    outbox_events
  ].freeze

  def change
    enable_extension "pgcrypto" unless extension_enabled?("pgcrypto")
    enable_extension "citext" unless extension_enabled?("citext")

    create_tenant_functions
    create_append_only_trigger_function

    create_table :tenants, id: :uuid do |t|
      t.citext :slug, null: false
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :tenants, :slug, unique: true

    create_table :parties, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.string :kind, null: false
      t.string :external_ref
      t.citext :document_number
      t.string :legal_name, null: false
      t.string :display_name
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :parties, "kind IN ('#{PARTY_KINDS.join("','")}')", name: "parties_kind_check"
    add_index :parties, %i[tenant_id kind external_ref], unique: true, where: "external_ref IS NOT NULL", name: "index_parties_on_tenant_kind_external_ref"
    add_index :parties, %i[tenant_id kind document_number], unique: true, where: "document_number IS NOT NULL", name: "index_parties_on_tenant_kind_document"

    create_table :physicians, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :party, null: false, type: :uuid, foreign_key: true
      t.string :full_name, null: false
      t.citext :email
      t.string :phone
      t.string :professional_registry
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :physicians, %i[tenant_id party_id], unique: true
    add_index :physicians, %i[tenant_id professional_registry], unique: true, where: "professional_registry IS NOT NULL"

    create_table :physician_legal_entity_memberships, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :physician_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :legal_entity_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :membership_role, null: false
      t.string :status, null: false, default: "ACTIVE"
      t.datetime :joined_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :left_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :physician_legal_entity_memberships, "membership_role IN ('#{MEMBERSHIP_ROLES.join("','")}')", name: "physician_membership_role_check"
    add_check_constraint :physician_legal_entity_memberships, "status IN ('#{MEMBERSHIP_STATUSES.join("','")}')", name: "physician_membership_status_check"
    add_index :physician_legal_entity_memberships, %i[tenant_id physician_party_id legal_entity_party_id], unique: true, name: "index_physician_memberships_unique"

    create_table :physician_anticipation_authorizations, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :legal_entity_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :granted_by_membership, null: false, type: :uuid, foreign_key: { to_table: :physician_legal_entity_memberships }
      t.references :beneficiary_physician_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :status, null: false, default: "ACTIVE"
      t.datetime :valid_from, null: false
      t.datetime :valid_until
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :physician_anticipation_authorizations, "status IN ('ACTIVE','REVOKED','EXPIRED')", name: "physician_authorization_status_check"
    add_index :physician_anticipation_authorizations, %i[tenant_id legal_entity_party_id beneficiary_physician_party_id], where: "status = 'ACTIVE'", name: "index_active_physician_authorizations"

    create_table :receivable_kinds, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true
      t.string :code, null: false
      t.string :name, null: false
      t.string :source_family, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :receivable_kinds, "source_family IN ('#{RECEIVABLE_FAMILIES.join("','")}')", name: "receivable_kinds_source_family_check"
    add_index :receivable_kinds, %i[tenant_id code], unique: true, name: "index_receivable_kinds_on_tenant_and_code"

    create_table :receivables, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable_kind, null: false, type: :uuid, foreign_key: true
      t.references :debtor_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :creditor_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :beneficiary_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :contract_reference
      t.string :external_reference
      t.decimal :gross_amount, precision: 18, scale: 2, null: false
      t.string :currency, null: false, default: "BRL", limit: 3
      t.datetime :performed_at, null: false
      t.datetime :due_at, null: false
      t.datetime :cutoff_at, null: false
      t.string :status, null: false, default: "PERFORMED"
      t.boolean :active, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :receivables, "gross_amount > 0", name: "receivables_gross_amount_positive_check"
    add_check_constraint :receivables, "status IN ('#{RECEIVABLE_STATUSES.join("','")}')", name: "receivables_status_check"
    add_index :receivables, %i[tenant_id status due_at], name: "index_receivables_on_tenant_status_due_at"
    add_index :receivables, %i[tenant_id external_reference], unique: true, where: "external_reference IS NOT NULL", name: "index_receivables_on_tenant_external_reference"

    create_table :receivable_allocations, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.integer :sequence, null: false
      t.references :allocated_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.references :physician_party, type: :uuid, foreign_key: { to_table: :parties }
      t.decimal :gross_amount, precision: 18, scale: 2, null: false
      t.decimal :tax_reserve_amount, precision: 18, scale: 2, null: false, default: 0
      t.boolean :eligible_for_anticipation, null: false, default: true
      t.string :status, null: false, default: "OPEN"
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :receivable_allocations, "gross_amount >= 0", name: "receivable_allocations_gross_amount_check"
    add_check_constraint :receivable_allocations, "tax_reserve_amount >= 0", name: "receivable_allocations_tax_reserve_amount_check"
    add_check_constraint :receivable_allocations, "status IN ('#{ALLOCATION_STATUSES.join("','")}')", name: "receivable_allocations_status_check"
    add_index :receivable_allocations, %i[receivable_id sequence], unique: true
    add_index :receivable_allocations, %i[tenant_id allocated_party_id], name: "index_receivable_allocations_on_tenant_allocated_party"

    create_table :anticipation_requests, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :receivable_allocation, type: :uuid, foreign_key: true
      t.references :requester_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :idempotency_key, null: false
      t.decimal :requested_amount, precision: 18, scale: 2, null: false
      t.decimal :discount_rate, precision: 12, scale: 8, null: false
      t.decimal :discount_amount, precision: 18, scale: 2, null: false
      t.decimal :net_amount, precision: 18, scale: 2, null: false
      t.string :status, null: false, default: "REQUESTED"
      t.string :channel, null: false, default: "API"
      t.datetime :requested_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :funded_at
      t.datetime :settled_at
      t.date :settlement_target_date
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :anticipation_requests, "requested_amount > 0", name: "anticipation_requests_requested_amount_positive_check"
    add_check_constraint :anticipation_requests, "discount_rate >= 0", name: "anticipation_requests_discount_rate_check"
    add_check_constraint :anticipation_requests, "discount_amount >= 0", name: "anticipation_requests_discount_amount_check"
    add_check_constraint :anticipation_requests, "net_amount > 0", name: "anticipation_requests_net_amount_positive_check"
    add_check_constraint :anticipation_requests, "status IN ('#{ANTICIPATION_STATUSES.join("','")}')", name: "anticipation_requests_status_check"
    add_check_constraint :anticipation_requests, "channel IN ('#{REQUEST_CHANNELS.join("','")}')", name: "anticipation_requests_channel_check"
    add_index :anticipation_requests, %i[tenant_id idempotency_key], unique: true
    add_index :anticipation_requests, %i[tenant_id receivable_id status], name: "index_anticipation_requests_on_tenant_receivable_status"

    create_table :receivable_events, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.bigint :sequence, null: false
      t.string :event_type, null: false
      t.references :actor_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :actor_role
      t.datetime :occurred_at, null: false
      t.string :request_id
      t.string :prev_hash
      t.string :event_hash, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :receivable_events, %i[receivable_id sequence], unique: true
    add_index :receivable_events, :event_hash, unique: true
    add_index :receivable_events, %i[tenant_id occurred_at], name: "index_receivable_events_on_tenant_occurred_at"

    create_table :documents, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :actor_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :document_type, null: false
      t.string :signature_method, null: false, default: "OWN_PLATFORM_CONFIRMATION"
      t.string :status, null: false, default: "SIGNED"
      t.string :sha256, null: false
      t.string :storage_key, null: false
      t.datetime :signed_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :documents, "status IN ('SIGNED','REVOKED','SUPERSEDED')", name: "documents_status_check"
    add_index :documents, %i[tenant_id sha256], unique: true
    add_index :documents, %i[tenant_id receivable_id], name: "index_documents_on_tenant_receivable"

    create_table :document_events, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :document, null: false, type: :uuid, foreign_key: true
      t.references :receivable, null: false, type: :uuid, foreign_key: true
      t.references :actor_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.string :request_id
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_index :document_events, %i[tenant_id document_id occurred_at], name: "index_document_events_on_tenant_document_occurred_at"

    create_table :auth_challenges, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :actor_party, null: false, type: :uuid, foreign_key: { to_table: :parties }
      t.string :purpose, null: false
      t.string :delivery_channel, null: false
      t.string :destination_masked, null: false
      t.string :code_digest, null: false
      t.string :status, null: false, default: "PENDING"
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 5
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.string :request_id
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :auth_challenges, "delivery_channel IN ('#{DELIVERY_CHANNELS.join("','")}')", name: "auth_challenges_delivery_channel_check"
    add_check_constraint :auth_challenges, "status IN ('#{AUTH_CHALLENGE_STATUSES.join("','")}')", name: "auth_challenges_status_check"
    add_check_constraint :auth_challenges, "attempts >= 0", name: "auth_challenges_attempts_check"
    add_check_constraint :auth_challenges, "max_attempts > 0", name: "auth_challenges_max_attempts_check"
    add_index :auth_challenges, %i[tenant_id actor_party_id status expires_at], name: "index_auth_challenges_active_by_actor"

    create_table :action_ip_logs, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :actor_party, type: :uuid, foreign_key: { to_table: :parties }
      t.string :action_type, null: false
      t.inet :ip_address, null: false
      t.string :user_agent
      t.string :request_id
      t.string :endpoint_path
      t.string :http_method
      t.string :channel, null: false
      t.string :target_type
      t.uuid :target_id
      t.boolean :success, null: false, default: true
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :action_ip_logs, "channel IN ('#{LOG_CHANNELS.join("','")}')", name: "action_ip_logs_channel_check"
    add_index :action_ip_logs, %i[tenant_id occurred_at], name: "index_action_ip_logs_on_tenant_occurred_at"
    add_index :action_ip_logs, %i[tenant_id actor_party_id occurred_at], name: "index_action_ip_logs_on_tenant_actor_occurred_at"
    add_index :action_ip_logs, %i[tenant_id request_id], name: "index_action_ip_logs_on_tenant_request_id"

    create_table :outbox_events, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.string :aggregate_type, null: false
      t.uuid :aggregate_id, null: false
      t.string :event_type, null: false
      t.string :status, null: false, default: "PENDING"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :sent_at
      t.string :idempotency_key
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
    add_check_constraint :outbox_events, "status IN ('#{EVENTABLE_STATUSES.join("','")}')", name: "outbox_events_status_check"
    add_index :outbox_events, %i[tenant_id status created_at], name: "index_outbox_events_pending_scan"
    add_index :outbox_events, %i[tenant_id idempotency_key], unique: true, where: "idempotency_key IS NOT NULL", name: "index_outbox_events_on_tenant_idempotency_key"

    create_table :receivable_statistics_daily, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.date :stat_date, null: false
      t.references :receivable_kind, null: false, type: :uuid, foreign_key: true
      t.string :metric_scope, null: false
      t.references :scope_party, type: :uuid, foreign_key: { to_table: :parties }
      t.bigint :receivable_count, null: false, default: 0
      t.decimal :gross_amount, precision: 18, scale: 2, null: false, default: 0
      t.bigint :anticipated_count, null: false, default: 0
      t.decimal :anticipated_amount, precision: 18, scale: 2, null: false, default: 0
      t.bigint :settled_count, null: false, default: 0
      t.decimal :settled_amount, precision: 18, scale: 2, null: false, default: 0
      t.datetime :last_computed_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end
    add_check_constraint :receivable_statistics_daily, "metric_scope IN ('#{METRIC_SCOPES.join("','")}')", name: "receivable_statistics_daily_metric_scope_check"
    add_index :receivable_statistics_daily, %i[tenant_id stat_date receivable_kind_id metric_scope scope_party_id], unique: true, name: "index_receivable_statistics_daily_unique_dimension"

    APPEND_ONLY_TABLES.each { |table| create_append_only_triggers(table) }
    SENSITIVE_TABLES.each { |table| enable_tenant_rls(table) }
  end

  private

  def create_tenant_functions
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_current_tenant_id()
      RETURNS uuid
      LANGUAGE sql
      STABLE
      AS $$
        SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
      $$;
    SQL
  end

  def create_append_only_trigger_function
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_forbid_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        RAISE EXCEPTION 'append-only table: % operation not allowed on %', TG_OP, TG_TABLE_NAME;
      END;
      $$;
    SQL
  end

  def create_append_only_triggers(table_name)
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
