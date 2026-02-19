require "test_helper"
require "digest"

class ProviderWebhookReceiptTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
  end

  test "validates uniqueness of provider event id per tenant and provider" do
    with_tenant_db_context(tenant_id: @tenant.id) do
      ProviderWebhookReceipt.create!(
        tenant: @tenant,
        provider: "QITECH",
        provider_event_id: "evt-unique-001",
        payload_sha256: Digest::SHA256.hexdigest("payload-1"),
        payload: { "status" => "SUCCESS" },
        request_headers: {},
        status: "PROCESSED",
        processed_at: Time.current
      )

      duplicate = ProviderWebhookReceipt.new(
        tenant: @tenant,
        provider: "QITECH",
        provider_event_id: "evt-unique-001",
        payload_sha256: Digest::SHA256.hexdigest("payload-1"),
        payload: { "status" => "SUCCESS" },
        request_headers: {},
        status: "PROCESSED",
        processed_at: Time.current
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:provider_event_id], "has already been taken"
    end
  end

  test "enables and forces RLS with tenant policy on provider webhook receipts" do
    connection = ActiveRecord::Base.connection

    rls_row = connection.select_one(<<~SQL)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'provider_webhook_receipts'::regclass
    SQL

    assert_equal true, rls_row["relrowsecurity"]
    assert_equal true, rls_row["relforcerowsecurity"]

    policy = connection.select_one(<<~SQL)
      SELECT policyname, qual, with_check
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'provider_webhook_receipts'
        AND policyname = 'provider_webhook_receipts_tenant_policy'
    SQL

    assert policy.present?
    assert_includes policy["qual"], "tenant_id"
    assert_includes policy["with_check"], "tenant_id"
  end
end
