# frozen_string_literal: true

module Api
  module V1
    class KycProfilePayloadPresenter
      CONTROL_PLANE_KEYS = %w[
        request_id
        storage_key
        sha256
        idempotency_key
        payload_hash
        provider_envelope_id
        email_challenge_id
        whatsapp_challenge_id
      ].freeze

      def profile(profile)
        {
          id: profile.id,
          tenant_id: profile.tenant_id,
          party_id: profile.party_id,
          status: profile.status,
          risk_level: profile.risk_level,
          submitted_at: profile.submitted_at&.iso8601,
          reviewed_at: profile.reviewed_at&.iso8601,
          reviewer_party_id: profile.reviewer_party_id,
          metadata: public_payload(profile.metadata),
          documents: profile.kyc_documents.order(created_at: :asc).map { |entry| document(entry) },
          events: profile.kyc_events.order(occurred_at: :asc).map { |entry| event(entry) }
        }
      end

      def document(document)
        {
          id: document.id,
          tenant_id: document.tenant_id,
          kyc_profile_id: document.kyc_profile_id,
          party_id: document.party_id,
          document_type: document.document_type,
          document_number: document.document_number,
          issuing_country: document.issuing_country,
          issuing_state: document.issuing_state,
          issued_on: document.issued_on&.iso8601,
          expires_on: document.expires_on&.iso8601,
          is_key_document: document.is_key_document,
          status: document.status,
          verified_at: document.verified_at&.iso8601,
          rejection_reason: document.rejection_reason,
          metadata: public_payload(document.metadata)
        }
      end

      private

      def event(event)
        {
          id: event.id,
          tenant_id: event.tenant_id,
          kyc_profile_id: event.kyc_profile_id,
          party_id: event.party_id,
          actor_party_id: event.actor_party_id,
          event_type: event.event_type,
          occurred_at: event.occurred_at&.iso8601,
          payload: public_payload(event.payload)
        }
      end

      def public_payload(raw_payload)
        normalized = MetadataSanitizer.normalize(raw_payload)
        return {} unless normalized.is_a?(Hash)

        allowed_keys = normalized.keys.reject { |key| CONTROL_PLANE_KEYS.include?(key.to_s) }
        MetadataSanitizer.sanitize(normalized, allowed_keys: allowed_keys)
      end
    end
  end
end
