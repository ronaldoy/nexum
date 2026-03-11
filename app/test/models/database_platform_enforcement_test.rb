require "test_helper"
require "digest"

class DatabasePlatformEnforcementTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @secondary_tenant = tenants(:secondary)
  end

  test "database platform constraints are fully validated" do
    unvalidated_constraints = connection.select_values(<<~SQL)
      SELECT conname
      FROM pg_constraint
      WHERE conname IN (#{Security::DatabaseSchemaAudit::REQUIRED_VALIDATED_CONSTRAINTS.map { |name| connection.quote(name) }.join(', ')})
        AND NOT convalidated
      ORDER BY conname
    SQL

    assert_equal [], unvalidated_constraints
  end

  test "active auth challenge enforcement uses a unique partial index" do
    index = connection.indexes(:auth_challenges).find { |candidate| candidate.name == "idx_auth_challenges_active_uniqueness_lookup" }

    assert index.present?
    assert_equal true, index.unique
    assert_includes index.where, "consumed_at IS NULL"
    assert_includes index.where, "PENDING"
    assert_includes index.where, "VERIFIED"
  end

  test "documents reject evidence mutation and deletion at the database layer" do
    document = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "documents-immutable")
      document = create_own_platform_document!(tenant: @tenant, receivable: bundle[:receivable], actor_party: bundle[:beneficiary], seed: "documents-immutable")
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      update_error = assert_raises(ActiveRecord::StatementInvalid) do
        document.update!(status: "REVOKED")
      end
      assert_match(/Only updated_at can change on documents/, update_error.message)

      delete_error = assert_raises(ActiveRecord::StatementInvalid) do
        document.destroy!
      end
      assert_match(/DELETE not allowed on documents/, delete_error.message)
    end
  end

  test "documents enforce own-platform evidence metadata" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "documents-metadata")

      error = assert_raises(ActiveRecord::StatementInvalid) do
        Document.create!(
          tenant: @tenant,
          receivable: bundle[:receivable],
          actor_party: bundle[:beneficiary],
          document_type: "ASSIGNMENT_TERM",
          signature_method: "OWN_PLATFORM_CONFIRMATION",
          status: "SIGNED",
          sha256: Digest::SHA256.hexdigest("documents-metadata"),
          storage_key: "documents/#{SecureRandom.uuid}",
          signed_at: Time.current,
          metadata: {}
        )
      end

      assert_match(/documents_own_platform_confirmation_metadata_check/, error.message)
    end
  end

  test "document composite foreign key rejects cross-tenant receivable references" do
    default_bundle = nil
    secondary_bundle = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "document-default")
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      secondary_bundle = create_receivable_bundle!(tenant: @secondary_tenant, suffix: "document-secondary")
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        create_own_platform_document!(
          tenant: @tenant,
          receivable: secondary_bundle[:receivable],
          actor_party: default_bundle[:beneficiary],
          seed: "cross-tenant-document"
        )
      end

      assert_match(/fk_documents_tenant_receivable/, error.message)
    end
  end

  test "anticipation requests reject cross-tenant requester parties" do
    default_bundle = nil
    secondary_bundle = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      default_bundle = create_receivable_bundle!(tenant: @tenant, suffix: "anticipation-default")
    end

    with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @secondary_tenant.id, role: "ops_admin") do
      secondary_bundle = create_receivable_bundle!(tenant: @secondary_tenant, suffix: "anticipation-secondary")
    end

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        AnticipationRequest.create!(
          tenant: @tenant,
          receivable: default_bundle[:receivable],
          receivable_allocation: default_bundle[:allocation],
          requester_party: secondary_bundle[:beneficiary],
          idempotency_key: "cross-tenant-requester-#{SecureRandom.hex(6)}",
          requested_amount: "100.00",
          discount_rate: "0.10000000",
          discount_amount: "10.00",
          net_amount: "90.00",
          status: "REQUESTED",
          channel: "API"
        )
      end

      assert_match(/fk_anticipation_requests_tenant_requester_party/, error.message)
    end
  end

  test "auth challenges reject duplicate active challenge state for the same actor target and channel" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "auth-duplicate")

      create_auth_challenge!(
        tenant: @tenant,
        actor_party: bundle[:beneficiary],
        target_id: bundle[:receivable].id,
        delivery_channel: "EMAIL",
        code: "123456",
        status: "PENDING"
      )

      error = assert_raises(ActiveRecord::StatementInvalid) do
        create_auth_challenge!(
          tenant: @tenant,
          actor_party: bundle[:beneficiary],
          target_id: bundle[:receivable].id,
          delivery_channel: "EMAIL",
          code: "654321",
          status: "PENDING"
        )
      end

      assert_match(/Active auth_challenge already exists/, error.message)
    end
  end

  test "auth challenges reject immutable identity mutation" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "auth-immutable")
      other_party = Party.create!(
        tenant: @tenant,
        kind: "SUPPLIER",
        legal_name: "Other auth actor",
        document_number: valid_cnpj_from_seed("auth-immutable-other")
      )

      challenge = create_auth_challenge!(
        tenant: @tenant,
        actor_party: bundle[:beneficiary],
        target_id: bundle[:receivable].id,
        delivery_channel: "EMAIL",
        code: "123456",
        status: "PENDING"
      )

      error = assert_raises(ActiveRecord::StatementInvalid) do
        challenge.update!(actor_party: other_party)
      end

      assert_match(/Only status, attempts, consumed_at, and updated_at can change on auth_challenges/, error.message)
    end
  end

  test "anticipation request discount math is enforced by the database" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      bundle = create_receivable_bundle!(tenant: @tenant, suffix: "anticipation-discount-db")

      error = assert_raises(ActiveRecord::StatementInvalid) do
        ActiveRecord::Base.transaction(requires_new: true) do
          connection.execute(<<~SQL)
            INSERT INTO anticipation_requests (
              id,
              tenant_id,
              receivable_id,
              receivable_allocation_id,
              requester_party_id,
              idempotency_key,
              requested_amount,
              discount_rate,
              discount_amount,
              net_amount,
              status,
              channel,
              requested_at,
              metadata,
              created_at,
              updated_at
            ) VALUES (
              #{connection.quote(SecureRandom.uuid)},
              #{connection.quote(@tenant.id)},
              #{connection.quote(bundle[:receivable].id)},
              #{connection.quote(bundle[:allocation].id)},
              #{connection.quote(bundle[:beneficiary].id)},
              #{connection.quote("anticipation-discount-db-#{SecureRandom.hex(6)}")},
              100.00,
              0.10000000,
              9.99,
              90.01,
              'REQUESTED',
              'API',
              #{connection.quote(Time.current)},
              '{}'::jsonb,
              #{connection.quote(Time.current)},
              #{connection.quote(Time.current)}
            )
          SQL
        end
      end

      assert_match(/anticipation_requests_discount_rounding_check|anticipation_requests_net_amount_breakdown_check/, error.message)
    end
  end

  test "failed provider webhook receipts require error details" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @tenant.id, role: "ops_admin") do
      error = assert_raises(ActiveRecord::StatementInvalid) do
        ProviderWebhookReceipt.create!(
          tenant: @tenant,
          provider: "QITECH",
          provider_event_id: "failed-without-error-#{SecureRandom.hex(4)}",
          payload_sha256: Digest::SHA256.hexdigest("provider-webhook-receipt"),
          payload: { "status" => "FAILED" },
          request_headers: {},
          status: "FAILED",
          processed_at: Time.current
        )
      end

      assert_match(/provider_webhook_receipts_failed_error_details_check/, error.message)
    end
  end

  private

  def create_receivable_bundle!(tenant:, suffix:)
    hospital = Party.create!(
      tenant: tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-hospital")
    )

    creditor = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Creditor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-creditor")
    )

    beneficiary = Party.create!(
      tenant: tenant,
      kind: "SUPPLIER",
      legal_name: "Beneficiary #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-beneficiary")
    )

    receivable_kind = ReceivableKind.create!(
      tenant: tenant,
      code: "database_platform_#{suffix}_#{SecureRandom.hex(4)}",
      name: "Database Platform #{suffix}",
      source_family: "SUPPLIER"
    )

    receivable = Receivable.create!(
      tenant: tenant,
      receivable_kind: receivable_kind,
      debtor_party: hospital,
      creditor_party: creditor,
      beneficiary_party: beneficiary,
      external_reference: "database-platform-#{suffix}-#{SecureRandom.hex(4)}",
      gross_amount: "100.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    allocation = ReceivableAllocation.create!(
      tenant: tenant,
      receivable: receivable,
      sequence: 1,
      allocated_party: beneficiary,
      gross_amount: "100.00",
      tax_reserve_amount: "0.00",
      status: "OPEN"
    )

    {
      hospital: hospital,
      creditor: creditor,
      beneficiary: beneficiary,
      receivable: receivable,
      allocation: allocation
    }
  end

  def create_own_platform_document!(tenant:, receivable:, actor_party:, seed:)
    Document.create!(
      tenant: tenant,
      receivable: receivable,
      actor_party: actor_party,
      document_type: "ASSIGNMENT_TERM",
      signature_method: "OWN_PLATFORM_CONFIRMATION",
      status: "SIGNED",
      sha256: Digest::SHA256.hexdigest(seed),
      storage_key: "documents/#{SecureRandom.uuid}",
      signed_at: Time.current,
      metadata: {
        "provider_envelope_id" => "env-#{seed}",
        "email_challenge_id" => SecureRandom.uuid,
        "whatsapp_challenge_id" => SecureRandom.uuid
      }
    )
  end

  def create_auth_challenge!(tenant:, actor_party:, target_id:, delivery_channel:, code:, status:)
    AuthChallenge.create!(
      tenant: tenant,
      actor_party: actor_party,
      purpose: "DOCUMENT_SIGNATURE_CONFIRMATION",
      delivery_channel: delivery_channel,
      destination_masked: delivery_channel == "EMAIL" ? "u***@example.com" : "+55*******123",
      code_digest: AuthChallenge.digest_code(code),
      status: status,
      attempts: status == "VERIFIED" ? 1 : 0,
      max_attempts: 5,
      expires_at: 30.minutes.from_now,
      request_id: SecureRandom.uuid,
      target_type: "Receivable",
      target_id: target_id,
      metadata: {}
    )
  end

  def connection
    ActiveRecord::Base.connection
  end
end
