module ApplicationHelper
  ROLE_LABELS = {
    "hospital_admin" => "Hospital",
    "supplier_user" => "Fornecedor",
    "ops_admin" => "FDIC",
    "physician_pf_user" => "Médico PF",
    "physician_pj_admin" => "Médico PJ Administrador",
    "physician_pj_member" => "Médico PJ Membro",
    "integration_api" => "Integração API"
  }.freeze

  STATUS_LABELS = {
    "performed" => "Performado",
    "anticipation_requested" => "Antecipação solicitada",
    "pending" => "Pendente",
    "approved" => "Aprovado",
    "rejected" => "Rejeitado",
    "funded" => "Antecipado",
    "settled" => "Liquidado",
    "failed" => "Falhou",
    "open" => "Aberto",
    "closed" => "Fechado",
    "cancelled" => "Cancelado",
    "expired" => "Expirado",
    "partially_settled" => "Parcialmente liquidado",
    "requested" => "Solicitado",
    "draft" => "Rascunho",
    "pending_review" => "Em análise",
    "needs_information" => "Informações pendentes",
    "submitted" => "Enviado",
    "verified" => "Verificado",
    "active" => "Ativo",
    "inactive" => "Inativo",
    "signed" => "Assinado",
    "revoked" => "Revogado"
  }.freeze

  def role_label(role, party: Current.user&.party)
    return "FDIC" if party&.kind == "FIDC"
    return "Organização Hospitalar" if hospital_organization_party?(party)
    return "Hospital" if party&.kind == "HOSPITAL"

    ROLE_LABELS.fetch(role.to_s, role.to_s.humanize)
  end

  def format_brl(value)
    number_to_currency(
      value.to_d,
      unit: "R$ ",
      separator: ",",
      delimiter: ".",
      format: "%u%n"
    )
  end

  def format_percentage(decimal_value, precision: 2)
    number_to_percentage(decimal_value.to_d * 100, precision: precision, separator: ",")
  end

  def status_label(value)
    key = value.to_s.downcase.strip.tr(" -", "__")
    STATUS_LABELS.fetch(key, key.tr("_", " ").capitalize)
  end

  private

  def hospital_organization_party?(party)
    return false if party.blank?
    return false unless %w[LEGAL_ENTITY_PJ PLATFORM].include?(party.kind)

    HospitalOwnership.where(
      tenant_id: party.tenant_id,
      organization_party_id: party.id,
      active: true
    ).exists?
  end
end
