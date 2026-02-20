# frozen_string_literal: true

module Api
  module V1
    class PhysicianPayloadPresenter
      def physician(physician, party)
        {
          id: physician.id,
          tenant_id: physician.tenant_id,
          party: party_payload(party),
          full_name: physician.full_name,
          email: physician.email,
          phone: physician.phone,
          crm_number: physician.crm_number,
          crm_state: physician.crm_state,
          active: physician.active,
          metadata: physician.metadata || {}
        }
      end

      private

      def party_payload(party)
        {
          id: party.id,
          external_ref: party.external_ref,
          kind: party.kind,
          legal_name: party.legal_name,
          display_name: party.display_name,
          document_type: party.document_type,
          document_number: party.document_number
        }
      end
    end
  end
end
