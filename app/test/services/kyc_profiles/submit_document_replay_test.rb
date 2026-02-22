require "test_helper"

module KycProfiles
  class SubmitDocumentReplayTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @party = parties(:default_supplier_party)
      @profile = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @party.id, role: "ops_admin") do
        @profile = KycProfile.create!(
          tenant: @tenant,
          party: @party,
          status: "DRAFT",
          risk_level: "UNKNOWN",
          metadata: {}
        )
      end
    end

    test "rejects replay when legacy outbox payload hash evidence is missing" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @party.id, role: "ops_admin") do
        idempotency_key = "kyc-submit-missing-hash-#{SecureRandom.hex(6)}"
        document = KycDocument.create!(
          tenant: @tenant,
          kyc_profile: @profile,
          party: @party,
          document_type: "RG",
          issuing_country: "BR",
          issuing_state: "SP",
          is_key_document: false,
          status: "SUBMITTED",
          storage_key: "kyc/legacy-submit-#{SecureRandom.hex(6)}.pdf",
          sha256: SecureRandom.hex(32),
          metadata: {}
        )

        insert_legacy_outbox_without_payload_hash!(
          tenant_id: @tenant.id,
          aggregate_type: "KycProfile",
          aggregate_id: @profile.id,
          event_type: "KYC_DOCUMENT_SUBMITTED",
          idempotency_key: idempotency_key,
          payload: {
            "kyc_profile_id" => @profile.id,
            "kyc_document_id" => document.id
          }
        )

        error = assert_raises(KycProfiles::SubmitDocument::IdempotencyConflict) do
          build_service(idempotency_key: idempotency_key).call(
            kyc_profile_id: @profile.id,
            raw_payload: {
              document_type: "RG",
              storage_key: "kyc/replay-input.pdf",
              sha256: "sha-replay-input"
            }
          )
        end

        assert_equal "idempotency_key_reused_without_payload_hash", error.code
      end
    end

    private

    def build_service(idempotency_key:)
      KycProfiles::SubmitDocument.new(
        tenant_id: @tenant.id,
        actor_role: "ops_admin",
        request_id: SecureRandom.uuid,
        idempotency_key: idempotency_key,
        request_ip: "127.0.0.1",
        user_agent: "test-agent",
        endpoint_path: "/api/v1/kyc_profiles/#{@profile.id}/submit_document",
        http_method: "POST"
      )
    end

    def insert_legacy_outbox_without_payload_hash!(tenant_id:, aggregate_type:, aggregate_id:, event_type:, idempotency_key:, payload:)
      connection = ActiveRecord::Base.connection
      timestamp = Time.utc(2026, 2, 21, 23, 59, 59)
      payload_json = payload.to_json

      connection.execute(<<~SQL)
        INSERT INTO outbox_events (
          id, tenant_id, aggregate_type, aggregate_id, event_type, status, attempts, idempotency_key, payload, created_at, updated_at
        ) VALUES (
          #{connection.quote(SecureRandom.uuid)},
          #{connection.quote(tenant_id)},
          #{connection.quote(aggregate_type)},
          #{connection.quote(aggregate_id)},
          #{connection.quote(event_type)},
          'PENDING',
          0,
          #{connection.quote(idempotency_key)},
          #{connection.quote(payload_json)}::jsonb,
          #{connection.quote(timestamp)},
          #{connection.quote(timestamp)}
        )
      SQL
    end
  end
end
