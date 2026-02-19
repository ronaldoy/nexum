module ReceivableProvenancePayload
  extend ActiveSupport::Concern

  private

  def receivable_provenance_payload(receivable)
    return nil unless receivable

    owning_organization = hospital_owning_organization_for(receivable)

    {
      hospital: party_reference_payload(receivable.debtor_party),
      owning_organization: party_reference_payload(owning_organization)
    }
  end

  def party_reference_payload(party)
    return nil unless party

    {
      id: party.id,
      kind: party.kind,
      legal_name: party.legal_name,
      document_type: party.document_type,
      document_number: party.document_number,
      external_reference: party.external_ref
    }
  end

  def hospital_owning_organization_for(receivable)
    hospital_party = receivable.debtor_party
    return receivable.creditor_party unless hospital_party&.kind == "HOSPITAL"

    ownership = hospital_party.hospital_ownerships
      .where(tenant_id: receivable.tenant_id, active: true)
      .includes(:organization_party)
      .order(created_at: :asc)
      .first

    ownership&.organization_party || receivable.creditor_party
  end
end
