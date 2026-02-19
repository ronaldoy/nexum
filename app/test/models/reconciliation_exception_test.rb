require "test_helper"
require "digest"

class ReconciliationExceptionTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @actor = users(:one)
  end

  test "capture creates a new open exception" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @actor.id, role: "worker") do
      captured = ReconciliationException.capture!(
        tenant_id: @tenant.id,
        source: "ESCROW_WEBHOOK",
        provider: "QITECH",
        external_event_id: "evt-capture-create",
        code: "escrow_webhook_resource_not_found",
        message: "Webhook payload did not match any escrow account or payout.",
        payload_sha256: Digest::SHA256.hexdigest("evt-capture-create"),
        payload: { "event_id" => "evt-capture-create" },
        metadata: { "request_id" => "req-capture-create" }
      )

      assert_equal "OPEN", captured.status
      assert_equal 1, captured.occurrences_count
      assert_equal "ESCROW_WEBHOOK", captured.source
      assert_equal "QITECH", captured.provider
    end
  end

  test "capture deduplicates by signature and increments occurrences" do
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @actor.id, role: "worker") do
      first = ReconciliationException.capture!(
        tenant_id: @tenant.id,
        source: "ESCROW_WEBHOOK",
        provider: "QITECH",
        external_event_id: "evt-capture-dedupe",
        code: "escrow_webhook_resource_not_found",
        message: "First message",
        payload_sha256: Digest::SHA256.hexdigest("evt-capture-dedupe-1")
      )

      first.update!(
        status: "RESOLVED",
        resolved_at: 5.minutes.ago,
        resolved_by_party_id: @actor.party_id
      )

      second = ReconciliationException.capture!(
        tenant_id: @tenant.id,
        source: "ESCROW_WEBHOOK",
        provider: "QITECH",
        external_event_id: "evt-capture-dedupe",
        code: "escrow_webhook_resource_not_found",
        message: "Second message",
        payload_sha256: Digest::SHA256.hexdigest("evt-capture-dedupe-2")
      )

      assert_equal first.id, second.id
      assert_equal "OPEN", second.status
      assert_equal 2, second.occurrences_count
      assert_nil second.resolved_at
      assert_nil second.resolved_by_party_id
      assert_equal "Second message", second.message
      assert_equal Digest::SHA256.hexdigest("evt-capture-dedupe-2"), second.payload_sha256
    end
  end
end
