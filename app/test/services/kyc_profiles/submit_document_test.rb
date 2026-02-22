require "test_helper"

module KycProfiles
  class SubmitDocumentTest < ActiveSupport::TestCase
    BlobDouble = Struct.new(:metadata, keyword_init: true)

    setup do
      @tenant = tenants(:default)
      @supplier_party = parties(:default_supplier_party)
      @other_party = parties(:secondary_supplier_party)
      @service = build_service
    end

    test "requires blob actor metadata when direct upload markers are present" do
      blob = BlobDouble.new(
        metadata: {
          "tenant_id" => @tenant.id,
          "direct_upload_actor_key" => "token:abc"
        }
      )

      error = assert_raises(KycProfiles::SubmitDocument::ValidationError) do
        @service.send(
          :validate_blob_actor_party_metadata!,
          blob: blob,
          expected_actor_party_id: @supplier_party.id
        )
      end

      assert_equal "missing_blob_actor_party_metadata", error.code
    end

    test "rejects actor mismatch when direct upload markers are present" do
      blob = BlobDouble.new(
        metadata: {
          "tenant_id" => @tenant.id,
          "actor_party_id" => @other_party.id,
          "direct_upload_idempotency_key" => SecureRandom.uuid
        }
      )

      error = assert_raises(KycProfiles::SubmitDocument::ValidationError) do
        @service.send(
          :validate_blob_actor_party_metadata!,
          blob: blob,
          expected_actor_party_id: @supplier_party.id
        )
      end

      assert_equal "blob_actor_party_mismatch", error.code
    end

    test "accepts matching actor metadata when direct upload markers are present" do
      blob = BlobDouble.new(
        metadata: {
          "tenant_id" => @tenant.id,
          "actor_party_id" => @supplier_party.id,
          "direct_upload_idempotency_key" => SecureRandom.uuid
        }
      )

      result = @service.send(
        :validate_blob_actor_party_metadata!,
        blob: blob,
        expected_actor_party_id: @supplier_party.id
      )

      assert_nil result
    end

    test "does not enforce actor metadata when blob is missing" do
      result = @service.send(
        :validate_blob_actor_party_metadata!,
        blob: nil,
        expected_actor_party_id: @supplier_party.id
      )

      assert_nil result
    end

    private

    def build_service
      KycProfiles::SubmitDocument.new(
        tenant_id: @tenant.id,
        actor_role: "ops_admin",
        request_id: SecureRandom.uuid,
        idempotency_key: SecureRandom.uuid,
        request_ip: "127.0.0.1",
        user_agent: "test-agent",
        endpoint_path: "/api/v1/kyc_profiles/test",
        http_method: "POST"
      )
    end
  end
end
