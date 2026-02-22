require "test_helper"

module Receivables
  class AttachSignedDocumentReplayTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:default)
      @supplier_party = parties(:default_supplier_party)
      @hospital_party = nil
      @receivable = nil

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @supplier_party.id, role: "ops_admin") do
        @hospital_party = Party.create!(
          tenant: @tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital Replay Test",
          document_number: valid_cnpj_from_seed("attach-replay-hospital")
        )
        kind = ReceivableKind.create!(
          tenant: @tenant,
          code: "supplier_invoice_attach_replay_#{SecureRandom.hex(4)}",
          name: "Supplier Invoice Attach Replay",
          source_family: "SUPPLIER"
        )
        @receivable = Receivable.create!(
          tenant: @tenant,
          receivable_kind: kind,
          debtor_party: @hospital_party,
          creditor_party: @supplier_party,
          beneficiary_party: @supplier_party,
          external_reference: "attach-replay-#{SecureRandom.hex(6)}",
          gross_amount: "100.00",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 5.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date),
          status: "PERFORMED",
          metadata: {}
        )
      end
    end

    test "rejects replay when legacy outbox payload hash evidence is missing" do
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @supplier_party.id, role: "ops_admin") do
        idempotency_key = "attach-doc-missing-hash-#{SecureRandom.hex(6)}"
        signed_at = Time.current
        document = Document.create!(
          tenant: @tenant,
          receivable: @receivable,
          actor_party: @supplier_party,
          document_type: "ASSIGNMENT_CONTRACT",
          signature_method: "OWN_PLATFORM_CONFIRMATION",
          status: "SIGNED",
          sha256: SecureRandom.hex(32),
          storage_key: "docs/legacy-attach-#{SecureRandom.hex(6)}.pdf",
          signed_at: signed_at,
          metadata: {
            "provider_envelope_id" => "env-legacy",
            "email_challenge_id" => SecureRandom.uuid,
            "whatsapp_challenge_id" => SecureRandom.uuid
          }
        )

        insert_legacy_outbox_without_payload_hash!(
          tenant_id: @tenant.id,
          aggregate_type: "Receivable",
          aggregate_id: @receivable.id,
          event_type: "RECEIVABLE_DOCUMENT_ATTACHED",
          idempotency_key: idempotency_key,
          payload: {
            "receivable_id" => @receivable.id,
            "document_id" => document.id
          }
        )

        error = assert_raises(Receivables::AttachSignedDocument::IdempotencyConflict) do
          build_service(idempotency_key: idempotency_key).call(
            receivable_id: @receivable.id,
            raw_payload: {
              actor_party_id: @supplier_party.id,
              document_type: "assignment_contract",
              sha256: "sha-input-replay",
              storage_key: "docs/input-replay.pdf",
              signed_at: signed_at.iso8601,
              provider_envelope_id: "env-input-replay",
              email_challenge_id: SecureRandom.uuid,
              whatsapp_challenge_id: SecureRandom.uuid
            },
            default_actor_party_id: @supplier_party.id,
            privileged_actor: true
          )
        end

        assert_equal "idempotency_key_reused_without_payload_hash", error.code
      end
    end

    private

    def build_service(idempotency_key:)
      Receivables::AttachSignedDocument.new(
        tenant_id: @tenant.id,
        actor_role: "ops_admin",
        request_id: SecureRandom.uuid,
        idempotency_key: idempotency_key,
        request_ip: "127.0.0.1",
        user_agent: "test-agent",
        endpoint_path: "/api/v1/receivables/#{@receivable.id}/attach_document",
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
