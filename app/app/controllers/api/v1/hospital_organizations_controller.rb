module Api
  module V1
    class HospitalOrganizationsController < Api::BaseController
      require_api_scopes(index: "receivables:read")

      include ReceivableProvenancePayload

      def index
        ownerships = visible_hospital_ownerships
        grouped = ownerships.group_by(&:organization_party_id)

        data = grouped.values.map do |entries|
          organization = entries.first.organization_party
          hospitals = entries
            .map(&:hospital_party)
            .uniq(&:id)
            .sort_by { |party| party.legal_name.to_s }

          {
            organization: party_reference_payload(organization),
            hospitals: hospitals.map { |party| party_reference_payload(party) }
          }
        end
        data.sort_by! { |entry| entry.dig(:organization, :legal_name).to_s }

        render json: {
          data: data,
          meta: { count: data.size }
        }
      end

      private

      def visible_hospital_ownerships
        scope = HospitalOwnership
          .where(tenant_id: Current.tenant_id, active: true)
          .includes(:organization_party, :hospital_party)

        return scope if privileged_actor?

        actor_party_id = current_actor_party_id
        raise AuthorizationError.new(code: "actor_party_required", message: "Access denied.") if actor_party_id.blank?

        scope.where(
          "organization_party_id = :actor_party_id OR hospital_party_id = :actor_party_id",
          actor_party_id: actor_party_id
        )
      end
    end
  end
end
