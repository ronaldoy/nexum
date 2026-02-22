require "test_helper"

module KycProfiles
  class CreateTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @party = parties(:default_supplier_party)
    end

    test "creates a profile and replays the same payload for the same idempotency key" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @party.id, role: "ops_admin") do
        idempotency_key = "kyc-create-replay-#{SecureRandom.hex(6)}"
        payload = { metadata: { source: "portal" } }
        service = build_service(idempotency_key:)

        first = service.call(payload, default_party_id: @party.id)
        second = service.call(payload, default_party_id: @party.id)

        assert_equal false, first.replayed?
        assert_equal true, second.replayed?
        assert_equal first.kyc_profile.id, second.kyc_profile.id
        assert_equal 1, KycProfile.where(tenant_id: @tenant.id, party_id: @party.id).count

        outbox = OutboxEvent.find_by!(tenant_id: @tenant.id, idempotency_key: idempotency_key)
        assert outbox.payload["payload_hash"].present?
      end
    end

    test "rejects same idempotency key with different payload" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @party.id, role: "ops_admin") do
        idempotency_key = "kyc-create-conflict-#{SecureRandom.hex(6)}"
        service = build_service(idempotency_key:)
        service.call({ metadata: { source: "portal" } }, default_party_id: @party.id)

        error = assert_raises(KycProfiles::Create::IdempotencyConflict) do
          service.call({ metadata: { source: "mobile" } }, default_party_id: @party.id)
        end

        assert_equal "idempotency_key_reused_with_different_payload", error.code
      end
    end

    test "rejects replay when stored outbox payload hash evidence is missing" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @party.id, role: "ops_admin") do
        idempotency_key = "kyc-create-missing-hash-#{SecureRandom.hex(6)}"
        payload = { metadata: { source: "portal" } }
        service = build_service(idempotency_key:)

        profile = KycProfile.create!(
          tenant_id: @tenant.id,
          party_id: @party.id,
          status: "DRAFT",
          risk_level: "UNKNOWN",
          metadata: {}
        )
        OutboxEvent.create!(
          tenant_id: @tenant.id,
          aggregate_type: "KycProfile",
          aggregate_id: profile.id,
          event_type: "KYC_PROFILE_CREATED",
          status: "PENDING",
          idempotency_key: idempotency_key,
          payload: { "kyc_profile_id" => profile.id }
        )

        error = assert_raises(KycProfiles::Create::IdempotencyConflict) do
          service.call(payload, default_party_id: @party.id)
        end

        assert_equal "idempotency_key_reused_without_payload_hash", error.code
      end
    end

    private

    def build_service(idempotency_key:)
      KycProfiles::Create.new(
        tenant_id: @tenant.id,
        actor_role: "ops_admin",
        request_id: SecureRandom.uuid,
        idempotency_key: idempotency_key,
        request_ip: "127.0.0.1",
        user_agent: "test-agent",
        endpoint_path: "/api/v1/kyc_profiles",
        http_method: "POST"
      )
    end
  end
end
