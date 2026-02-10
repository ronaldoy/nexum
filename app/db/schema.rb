# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_02_10_160001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "action_ip_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action_type", null: false
    t.uuid "actor_party_id"
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "endpoint_path"
    t.string "http_method"
    t.inet "ip_address", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "occurred_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "request_id"
    t.boolean "success", default: true, null: false
    t.uuid "target_id"
    t.string "target_type"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["actor_party_id"], name: "index_action_ip_logs_on_actor_party_id"
    t.index ["tenant_id", "actor_party_id", "occurred_at"], name: "index_action_ip_logs_on_tenant_actor_occurred_at"
    t.index ["tenant_id", "occurred_at"], name: "index_action_ip_logs_on_tenant_occurred_at"
    t.index ["tenant_id", "request_id"], name: "index_action_ip_logs_on_tenant_request_id"
    t.index ["tenant_id"], name: "index_action_ip_logs_on_tenant_id"
    t.check_constraint "channel::text = ANY (ARRAY['API'::character varying, 'PORTAL'::character varying, 'WORKER'::character varying, 'WEBHOOK'::character varying, 'ADMIN'::character varying]::text[])", name: "action_ip_logs_channel_check"
  end

  create_table "anticipation_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "channel", default: "API", null: false
    t.datetime "created_at", null: false
    t.decimal "discount_amount", precision: 18, scale: 2, null: false
    t.decimal "discount_rate", precision: 12, scale: 8, null: false
    t.datetime "funded_at"
    t.string "idempotency_key", null: false
    t.jsonb "metadata", default: {}, null: false
    t.decimal "net_amount", precision: 18, scale: 2, null: false
    t.uuid "receivable_allocation_id"
    t.uuid "receivable_id", null: false
    t.decimal "requested_amount", precision: 18, scale: 2, null: false
    t.datetime "requested_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "requester_party_id", null: false
    t.datetime "settled_at"
    t.date "settlement_target_date"
    t.string "status", default: "REQUESTED", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receivable_allocation_id"], name: "index_anticipation_requests_on_receivable_allocation_id"
    t.index ["receivable_id"], name: "index_anticipation_requests_on_receivable_id"
    t.index ["requester_party_id"], name: "index_anticipation_requests_on_requester_party_id"
    t.index ["tenant_id", "idempotency_key"], name: "index_anticipation_requests_on_tenant_id_and_idempotency_key", unique: true
    t.index ["tenant_id", "receivable_id", "status"], name: "index_anticipation_requests_on_tenant_receivable_status"
    t.index ["tenant_id"], name: "index_anticipation_requests_on_tenant_id"
    t.check_constraint "channel::text = ANY (ARRAY['API'::character varying, 'PORTAL'::character varying, 'WEBHOOK'::character varying, 'INTERNAL'::character varying]::text[])", name: "anticipation_requests_channel_check"
    t.check_constraint "discount_amount >= 0::numeric", name: "anticipation_requests_discount_amount_check"
    t.check_constraint "discount_rate >= 0::numeric", name: "anticipation_requests_discount_rate_check"
    t.check_constraint "net_amount > 0::numeric", name: "anticipation_requests_net_amount_positive_check"
    t.check_constraint "requested_amount > 0::numeric", name: "anticipation_requests_requested_amount_positive_check"
    t.check_constraint "status::text = ANY (ARRAY['REQUESTED'::character varying, 'APPROVED'::character varying, 'FUNDED'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying, 'REJECTED'::character varying]::text[])", name: "anticipation_requests_status_check"
  end

  create_table "api_access_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: [], null: false, array: true
    t.uuid "tenant_id", null: false
    t.string "token_digest", null: false
    t.string "token_identifier", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["tenant_id", "revoked_at", "expires_at"], name: "index_api_access_tokens_on_tenant_lifecycle"
    t.index ["tenant_id"], name: "index_api_access_tokens_on_tenant_id"
    t.index ["token_identifier"], name: "index_api_access_tokens_on_token_identifier", unique: true
    t.index ["user_id"], name: "index_api_access_tokens_on_user_id"
    t.check_constraint "char_length(token_digest::text) > 0", name: "api_access_tokens_token_digest_check"
    t.check_constraint "char_length(token_identifier::text) > 0", name: "api_access_tokens_token_identifier_check"
  end

  create_table "auth_challenges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_party_id", null: false
    t.integer "attempts", default: 0, null: false
    t.string "code_digest", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "delivery_channel", null: false
    t.string "destination_masked", null: false
    t.datetime "expires_at", null: false
    t.integer "max_attempts", default: 5, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "purpose", null: false
    t.string "request_id"
    t.string "status", default: "PENDING", null: false
    t.uuid "target_id", null: false
    t.string "target_type", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_party_id"], name: "index_auth_challenges_on_actor_party_id"
    t.index ["tenant_id", "actor_party_id", "status", "expires_at"], name: "index_auth_challenges_active_by_actor"
    t.index ["tenant_id"], name: "index_auth_challenges_on_tenant_id"
    t.check_constraint "attempts >= 0", name: "auth_challenges_attempts_check"
    t.check_constraint "delivery_channel::text = ANY (ARRAY['EMAIL'::character varying, 'WHATSAPP'::character varying]::text[])", name: "auth_challenges_delivery_channel_check"
    t.check_constraint "max_attempts > 0", name: "auth_challenges_max_attempts_check"
    t.check_constraint "status::text = ANY (ARRAY['PENDING'::character varying, 'VERIFIED'::character varying, 'EXPIRED'::character varying, 'CANCELLED'::character varying]::text[])", name: "auth_challenges_status_check"
  end

  create_table "document_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_party_id"
    t.datetime "created_at", null: false
    t.uuid "document_id", null: false
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.uuid "receivable_id", null: false
    t.string "request_id"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_party_id"], name: "index_document_events_on_actor_party_id"
    t.index ["document_id"], name: "index_document_events_on_document_id"
    t.index ["receivable_id"], name: "index_document_events_on_receivable_id"
    t.index ["tenant_id", "document_id", "occurred_at"], name: "index_document_events_on_tenant_document_occurred_at"
    t.index ["tenant_id"], name: "index_document_events_on_tenant_id"
  end

  create_table "documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_party_id", null: false
    t.datetime "created_at", null: false
    t.string "document_type", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "receivable_id", null: false
    t.string "sha256", null: false
    t.string "signature_method", default: "OWN_PLATFORM_CONFIRMATION", null: false
    t.datetime "signed_at", null: false
    t.string "status", default: "SIGNED", null: false
    t.string "storage_key", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_party_id"], name: "index_documents_on_actor_party_id"
    t.index ["receivable_id"], name: "index_documents_on_receivable_id"
    t.index ["tenant_id", "receivable_id"], name: "index_documents_on_tenant_receivable"
    t.index ["tenant_id", "sha256"], name: "index_documents_on_tenant_id_and_sha256", unique: true
    t.index ["tenant_id"], name: "index_documents_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['SIGNED'::character varying, 'REVOKED'::character varying, 'SUPERSEDED'::character varying]::text[])", name: "documents_status_check"
  end

  create_table "outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "aggregate_id", null: false
    t.string "aggregate_type", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "idempotency_key"
    t.datetime "next_attempt_at"
    t.jsonb "payload", default: {}, null: false
    t.datetime "sent_at"
    t.string "status", default: "PENDING", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "idempotency_key"], name: "index_outbox_events_on_tenant_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["tenant_id", "status", "created_at"], name: "index_outbox_events_pending_scan"
    t.index ["tenant_id"], name: "index_outbox_events_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['PENDING'::character varying, 'SENT'::character varying, 'FAILED'::character varying, 'CANCELLED'::character varying]::text[])", name: "outbox_events_status_check"
  end

  create_table "parties", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.citext "document_number"
    t.string "external_ref"
    t.string "kind", null: false
    t.string "legal_name", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "kind", "document_number"], name: "index_parties_on_tenant_kind_document", unique: true, where: "(document_number IS NOT NULL)"
    t.index ["tenant_id", "kind", "external_ref"], name: "index_parties_on_tenant_kind_external_ref", unique: true, where: "(external_ref IS NOT NULL)"
    t.index ["tenant_id"], name: "index_parties_on_tenant_id"
    t.check_constraint "kind::text = ANY (ARRAY['HOSPITAL'::character varying, 'SUPPLIER'::character varying, 'PHYSICIAN_PF'::character varying, 'LEGAL_ENTITY_PJ'::character varying, 'FIDC'::character varying, 'PLATFORM'::character varying]::text[])", name: "parties_kind_check"
  end

  create_table "physician_anticipation_authorizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "beneficiary_physician_party_id", null: false
    t.datetime "created_at", null: false
    t.uuid "granted_by_membership_id", null: false
    t.uuid "legal_entity_party_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "status", default: "ACTIVE", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_from", null: false
    t.datetime "valid_until"
    t.index ["beneficiary_physician_party_id"], name: "idx_on_beneficiary_physician_party_id_49cb368edd"
    t.index ["granted_by_membership_id"], name: "idx_on_granted_by_membership_id_ba97263f49"
    t.index ["legal_entity_party_id"], name: "idx_on_legal_entity_party_id_67e9dbdf42"
    t.index ["tenant_id", "legal_entity_party_id", "beneficiary_physician_party_id"], name: "index_active_physician_authorizations", where: "((status)::text = 'ACTIVE'::text)"
    t.index ["tenant_id"], name: "index_physician_anticipation_authorizations_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['ACTIVE'::character varying, 'REVOKED'::character varying, 'EXPIRED'::character varying]::text[])", name: "physician_authorization_status_check"
  end

  create_table "physician_legal_entity_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "joined_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "left_at"
    t.uuid "legal_entity_party_id", null: false
    t.string "membership_role", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "physician_party_id", null: false
    t.string "status", default: "ACTIVE", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["legal_entity_party_id"], name: "idx_on_legal_entity_party_id_0544188f89"
    t.index ["physician_party_id"], name: "index_physician_legal_entity_memberships_on_physician_party_id"
    t.index ["tenant_id", "physician_party_id", "legal_entity_party_id"], name: "index_physician_memberships_unique", unique: true
    t.index ["tenant_id"], name: "index_physician_legal_entity_memberships_on_tenant_id"
    t.check_constraint "membership_role::text = ANY (ARRAY['ADMIN'::character varying, 'MEMBER'::character varying]::text[])", name: "physician_membership_role_check"
    t.check_constraint "status::text = ANY (ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying]::text[])", name: "physician_membership_status_check"
  end

  create_table "physicians", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.citext "email"
    t.string "full_name", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "party_id", null: false
    t.string "phone"
    t.string "professional_registry"
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["party_id"], name: "index_physicians_on_party_id"
    t.index ["tenant_id", "party_id"], name: "index_physicians_on_tenant_id_and_party_id", unique: true
    t.index ["tenant_id", "professional_registry"], name: "index_physicians_on_tenant_id_and_professional_registry", unique: true, where: "(professional_registry IS NOT NULL)"
    t.index ["tenant_id"], name: "index_physicians_on_tenant_id"
  end

  create_table "receivable_allocations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "allocated_party_id", null: false
    t.datetime "created_at", null: false
    t.boolean "eligible_for_anticipation", default: true, null: false
    t.decimal "gross_amount", precision: 18, scale: 2, null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "physician_party_id"
    t.uuid "receivable_id", null: false
    t.integer "sequence", null: false
    t.string "status", default: "OPEN", null: false
    t.decimal "tax_reserve_amount", precision: 18, scale: 2, default: "0.0", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["allocated_party_id"], name: "index_receivable_allocations_on_allocated_party_id"
    t.index ["physician_party_id"], name: "index_receivable_allocations_on_physician_party_id"
    t.index ["receivable_id", "sequence"], name: "index_receivable_allocations_on_receivable_id_and_sequence", unique: true
    t.index ["receivable_id"], name: "index_receivable_allocations_on_receivable_id"
    t.index ["tenant_id", "allocated_party_id"], name: "index_receivable_allocations_on_tenant_allocated_party"
    t.index ["tenant_id"], name: "index_receivable_allocations_on_tenant_id"
    t.check_constraint "gross_amount >= 0::numeric", name: "receivable_allocations_gross_amount_check"
    t.check_constraint "status::text = ANY (ARRAY['OPEN'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying]::text[])", name: "receivable_allocations_status_check"
    t.check_constraint "tax_reserve_amount >= 0::numeric", name: "receivable_allocations_tax_reserve_amount_check"
  end

  create_table "receivable_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "actor_party_id"
    t.string "actor_role"
    t.datetime "created_at", null: false
    t.string "event_hash", null: false
    t.string "event_type", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "prev_hash"
    t.uuid "receivable_id", null: false
    t.string "request_id"
    t.bigint "sequence", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_party_id"], name: "index_receivable_events_on_actor_party_id"
    t.index ["event_hash"], name: "index_receivable_events_on_event_hash", unique: true
    t.index ["receivable_id", "sequence"], name: "index_receivable_events_on_receivable_id_and_sequence", unique: true
    t.index ["receivable_id"], name: "index_receivable_events_on_receivable_id"
    t.index ["tenant_id", "occurred_at"], name: "index_receivable_events_on_tenant_occurred_at"
    t.index ["tenant_id"], name: "index_receivable_events_on_tenant_id"
  end

  create_table "receivable_kinds", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "source_family", null: false
    t.uuid "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "code"], name: "index_receivable_kinds_on_tenant_and_code", unique: true
    t.index ["tenant_id"], name: "index_receivable_kinds_on_tenant_id"
    t.check_constraint "source_family::text = ANY (ARRAY['PHYSICIAN'::character varying, 'SUPPLIER'::character varying, 'OTHER'::character varying]::text[])", name: "receivable_kinds_source_family_check"
  end

  create_table "receivable_statistics_daily", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "anticipated_amount", precision: 18, scale: 2, default: "0.0", null: false
    t.bigint "anticipated_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.decimal "gross_amount", precision: 18, scale: 2, default: "0.0", null: false
    t.datetime "last_computed_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "metric_scope", null: false
    t.bigint "receivable_count", default: 0, null: false
    t.uuid "receivable_kind_id", null: false
    t.uuid "scope_party_id"
    t.decimal "settled_amount", precision: 18, scale: 2, default: "0.0", null: false
    t.bigint "settled_count", default: 0, null: false
    t.date "stat_date", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["receivable_kind_id"], name: "index_receivable_statistics_daily_on_receivable_kind_id"
    t.index ["scope_party_id"], name: "index_receivable_statistics_daily_on_scope_party_id"
    t.index ["tenant_id", "stat_date", "receivable_kind_id", "metric_scope", "scope_party_id"], name: "index_receivable_statistics_daily_unique_dimension", unique: true
    t.index ["tenant_id"], name: "index_receivable_statistics_daily_on_tenant_id"
    t.check_constraint "metric_scope::text = ANY (ARRAY['GLOBAL'::character varying, 'DEBTOR'::character varying, 'CREDITOR'::character varying, 'BENEFICIARY'::character varying]::text[])", name: "receivable_statistics_daily_metric_scope_check"
  end

  create_table "receivables", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.uuid "beneficiary_party_id", null: false
    t.string "contract_reference"
    t.datetime "created_at", null: false
    t.uuid "creditor_party_id", null: false
    t.string "currency", limit: 3, default: "BRL", null: false
    t.datetime "cutoff_at", null: false
    t.uuid "debtor_party_id", null: false
    t.datetime "due_at", null: false
    t.string "external_reference"
    t.decimal "gross_amount", precision: 18, scale: 2, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "performed_at", null: false
    t.uuid "receivable_kind_id", null: false
    t.string "status", default: "PERFORMED", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["beneficiary_party_id"], name: "index_receivables_on_beneficiary_party_id"
    t.index ["creditor_party_id"], name: "index_receivables_on_creditor_party_id"
    t.index ["debtor_party_id"], name: "index_receivables_on_debtor_party_id"
    t.index ["receivable_kind_id"], name: "index_receivables_on_receivable_kind_id"
    t.index ["tenant_id", "external_reference"], name: "index_receivables_on_tenant_external_reference", unique: true, where: "(external_reference IS NOT NULL)"
    t.index ["tenant_id", "status", "due_at"], name: "index_receivables_on_tenant_status_due_at"
    t.index ["tenant_id"], name: "index_receivables_on_tenant_id"
    t.check_constraint "gross_amount > 0::numeric", name: "receivables_gross_amount_positive_check"
    t.check_constraint "status::text = ANY (ARRAY['PERFORMED'::character varying, 'ANTICIPATION_REQUESTED'::character varying, 'FUNDED'::character varying, 'SETTLED'::character varying, 'CANCELLED'::character varying]::text[])", name: "receivables_status_check"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tenants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.citext "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.uuid "party_id"
    t.string "password_digest", null: false
    t.string "role", default: "supplier_user", null: false
    t.uuid "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["party_id"], name: "index_users_on_party_id"
    t.index ["tenant_id"], name: "index_users_on_tenant_id"
  end

  add_foreign_key "action_ip_logs", "parties", column: "actor_party_id"
  add_foreign_key "action_ip_logs", "tenants"
  add_foreign_key "anticipation_requests", "parties", column: "requester_party_id"
  add_foreign_key "anticipation_requests", "receivable_allocations"
  add_foreign_key "anticipation_requests", "receivables"
  add_foreign_key "anticipation_requests", "tenants"
  add_foreign_key "api_access_tokens", "tenants"
  add_foreign_key "api_access_tokens", "users"
  add_foreign_key "auth_challenges", "parties", column: "actor_party_id"
  add_foreign_key "auth_challenges", "tenants"
  add_foreign_key "document_events", "documents"
  add_foreign_key "document_events", "parties", column: "actor_party_id"
  add_foreign_key "document_events", "receivables"
  add_foreign_key "document_events", "tenants"
  add_foreign_key "documents", "parties", column: "actor_party_id"
  add_foreign_key "documents", "receivables"
  add_foreign_key "documents", "tenants"
  add_foreign_key "outbox_events", "tenants"
  add_foreign_key "parties", "tenants"
  add_foreign_key "physician_anticipation_authorizations", "parties", column: "beneficiary_physician_party_id"
  add_foreign_key "physician_anticipation_authorizations", "parties", column: "legal_entity_party_id"
  add_foreign_key "physician_anticipation_authorizations", "physician_legal_entity_memberships", column: "granted_by_membership_id"
  add_foreign_key "physician_anticipation_authorizations", "tenants"
  add_foreign_key "physician_legal_entity_memberships", "parties", column: "legal_entity_party_id"
  add_foreign_key "physician_legal_entity_memberships", "parties", column: "physician_party_id"
  add_foreign_key "physician_legal_entity_memberships", "tenants"
  add_foreign_key "physicians", "parties"
  add_foreign_key "physicians", "tenants"
  add_foreign_key "receivable_allocations", "parties", column: "allocated_party_id"
  add_foreign_key "receivable_allocations", "parties", column: "physician_party_id"
  add_foreign_key "receivable_allocations", "receivables"
  add_foreign_key "receivable_allocations", "tenants"
  add_foreign_key "receivable_events", "parties", column: "actor_party_id"
  add_foreign_key "receivable_events", "receivables"
  add_foreign_key "receivable_events", "tenants"
  add_foreign_key "receivable_kinds", "tenants"
  add_foreign_key "receivable_statistics_daily", "parties", column: "scope_party_id"
  add_foreign_key "receivable_statistics_daily", "receivable_kinds"
  add_foreign_key "receivable_statistics_daily", "tenants"
  add_foreign_key "receivables", "parties", column: "beneficiary_party_id"
  add_foreign_key "receivables", "parties", column: "creditor_party_id"
  add_foreign_key "receivables", "parties", column: "debtor_party_id"
  add_foreign_key "receivables", "receivable_kinds"
  add_foreign_key "receivables", "tenants"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "parties"
  add_foreign_key "users", "tenants"
end
