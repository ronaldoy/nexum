module Api
  module V1
    class HospitalOrganizationsController < Api::BaseController
      require_api_scopes(index: "receivables:read")

      include ReceivableProvenancePayload

      ORGANIZATION_VISIBILITY_SQL = <<~SQL.squish.freeze
        organization_party_id = :actor_party_id
        OR hospital_party_id = :actor_party_id
      SQL

      def index
        data = organization_group_payloads
        render_index_response(data)
      end

      private

      def organization_group_payloads
        visible_hospital_ownerships
          .group_by(&:organization_party_id)
          .values
          .map { |ownership_entries| organization_group_payload(ownership_entries) }
          .sort_by { |payload| payload.dig(:organization, :legal_name).to_s }
      end

      def organization_group_payload(ownership_entries)
        organization = ownership_entries.first.organization_party
        {
          organization: party_reference_payload(organization),
          hospitals: hospital_payloads(ownership_entries)
        }
      end

      def hospital_payloads(ownership_entries)
        ownership_entries
          .map(&:hospital_party)
          .uniq(&:id)
          .sort_by { |party| party.legal_name.to_s }
          .map { |party| party_reference_payload(party) }
      end

      def render_index_response(data)
        render json: { data: data, meta: { count: data.size } }
      end

      def visible_hospital_ownerships
        scope = HospitalOwnership
          .where(tenant_id: Current.tenant_id, active: true)
          .includes(:organization_party, :hospital_party)

        return scope if privileged_actor?

        scope.where(ORGANIZATION_VISIBILITY_SQL, actor_party_id: require_actor_party_id!)
      end

      def require_actor_party_id!
        actor_party_id = current_actor_party_id
        return actor_party_id if actor_party_id.present?

        raise AuthorizationError.new(code: "actor_party_required", message: "Access denied.")
      end
    end
  end
end
