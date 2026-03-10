module ApplicationHelper
  PLATFORM_NAME = "Averta".freeze
  SEED_PRIVILEGED_MFA_SECRET = ENV["AVERTA_SEED_MFA_SECRET"].presence || "JBSWY3DPEHPK3PXP"

  ROLE_LABELS = {
    "hospital_admin" => "Hospital",
    "supplier_user" => "Fornecedor",
    "ops_admin" => "Gestão FDIC",
    "physician_pf_user" => "Médico PF",
    "physician_pj_admin" => "Médico PJ Administrador",
    "physician_pj_member" => "Médico PJ Membro",
    "integration_api" => "Integração API"
  }.freeze

  PARTY_KIND_LABELS = {
    "HOSPITAL" => "Hospital",
    "SUPPLIER" => "Fornecedor",
    "PHYSICIAN_PF" => "Médico PF",
    "LEGAL_ENTITY_PJ" => "Pessoa jurídica",
    "FIDC" => "FDIC",
    "PLATFORM" => "Plataforma"
  }.freeze

  STATUS_LABELS = {
    "performed" => "Performado",
    "anticipation_requested" => "Antecipação solicitada",
    "pending" => "Pendente",
    "approved" => "Aprovado",
    "rejected" => "Rejeitado",
    "funded" => "Funded",
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

  def platform_name
    PLATFORM_NAME
  end

  def role_label(role, party: Current.user&.party)
    return "FDIC" if party&.kind == "FIDC"
    return "Organização Hospitalar" if hospital_organization_party?(party)
    return "Hospital" if party&.kind == "HOSPITAL"

    ROLE_LABELS.fetch(role.to_s, role.to_s.humanize)
  end

  def party_kind_label(kind)
    PARTY_KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
  end

  def admin_nav_link_class(path)
    classes = [ "topbar-nav-link" ]
    classes << "topbar-nav-link-active" if request.path == path || request.path.start_with?("#{path}/")
    classes.join(" ")
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

  def party_display_name(party)
    party&.display_name.presence || party&.legal_name || "-"
  end

  def loan_structure_label(anticipation_request, allocation: anticipation_request&.receivable_allocation)
    requester_kind = anticipation_request&.requester_party&.kind
    return "Médico via PJ" if requester_kind == "LEGAL_ENTITY_PJ" && allocation&.physician_party.present?
    return "Médico PF direto" if requester_kind == "PHYSICIAN_PF"

    party_kind_label(requester_kind)
  end

  def loan_structure_note(anticipation_request, allocation: anticipation_request&.receivable_allocation)
    requester = anticipation_request&.requester_party
    linked_physician = allocation&.physician_party

    if requester&.kind == "LEGAL_ENTITY_PJ" && linked_physician.present?
      "Solicitante PJ com medico vinculado em #{party_display_name(linked_physician)}"
    elsif requester&.kind == "PHYSICIAN_PF"
      "Solicitacao feita diretamente pelo medico titular"
    else
      "Solicitacao feita por #{party_kind_label(requester&.kind)}"
    end
  end

  def seed_privileged_mfa_code
    ROTP::TOTP.new(SEED_PRIVILEGED_MFA_SECRET).now
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
