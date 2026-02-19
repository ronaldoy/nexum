# frozen_string_literal: true

require "digest"

module DemoSeeds
  module_function

  PASSWORD = "Nexum@2026"

  def run!
    puts "== Nexum Capital demo seed =="

    tenant = Tenant.find_or_create_by!(slug: "demo-br") do |record|
      record.name = "Nexum Capital Demo Brasil"
      record.active = true
    end
    secondary_tenant = Tenant.find_or_create_by!(slug: "demo-isolado") do |record|
      record.name = "Tenant Isolado"
      record.active = true
    end

    seed_tenant!(tenant)
    seed_secondary_tenant!(secondary_tenant)

    puts "Dados de demonstração prontos."
    puts "Login Hospital: hospital_admin@demo.nexum.capital"
    puts "Login Fornecedor: supplier_user@demo.nexum.capital"
    puts "Login Médico: physician_user@demo.nexum.capital"
    puts "Login FDIC: fdic_user@demo.nexum.capital"
    puts "Senha para todos: #{PASSWORD}"
  end

  def seed_tenant!(tenant)
    with_tenant_context(tenant_id: tenant.id, role: "seed_runner") do
      parties = seed_parties!(tenant)
      kinds = seed_receivable_kinds!(tenant)
      seed_physicians!(tenant, parties)
      seed_physician_memberships!(tenant, parties)
      seed_split_policy!(tenant, parties)
      seed_users!(tenant, parties)
      build_receivable_scenarios!(tenant, parties, kinds)
      seed_daily_statistics!(tenant, kinds)
    end
  end

  def seed_secondary_tenant!(tenant)
    with_tenant_context(tenant_id: tenant.id, role: "seed_runner") do
      hospital = upsert_party!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital Tenant Isolado",
        display_name: "Hospital Isolado",
        seed_key: "secondary-hospital"
      )
      supplier = upsert_party!(
        tenant: tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor Tenant Isolado",
        display_name: "Fornecedor Isolado",
        seed_key: "secondary-supplier"
      )
      kind = ReceivableKind.find_or_create_by!(tenant: tenant, code: "supplier_invoice") do |record|
        record.name = "Fatura de Fornecedor"
        record.source_family = "SUPPLIER"
      end

      user = User.find_or_initialize_by(email_address: "isolated_user@demo.nexum.capital")
      user.tenant = tenant
      user.party = supplier
      user.role = "supplier_user"
      user.password = PASSWORD
      user.password_confirmation = PASSWORD
      user.save!

      receivable = Receivable.find_or_initialize_by(
        tenant: tenant,
        external_reference: "SIM-ISOLADO-001"
      )
      receivable.assign_attributes(
        receivable_kind: kind,
        debtor_party: hospital,
        creditor_party: supplier,
        beneficiary_party: supplier,
        gross_amount: money("12000"),
        currency: "BRL",
        performed_at: 5.days.ago,
        due_at: 15.days.from_now,
        cutoff_at: BusinessCalendar.cutoff_at(5.days.ago.to_date),
        status: "PERFORMED",
        metadata: { "seed_scenario" => "isolated_tenant" }
      )
      receivable.save!

      allocation = ReceivableAllocation.find_or_initialize_by(
        tenant: tenant,
        receivable: receivable,
        sequence: 1
      )
      allocation.assign_attributes(
        allocated_party: supplier,
        gross_amount: receivable.gross_amount,
        tax_reserve_amount: money("0"),
        status: "OPEN",
        eligible_for_anticipation: true,
        metadata: { "seed_scenario" => "isolated_tenant" }
      )
      allocation.save!
    end
  end

  def seed_parties!(tenant)
    {
      hospital: upsert_party!(
        tenant: tenant,
        kind: "HOSPITAL",
        legal_name: "Hospital Santa Aurora",
        display_name: "Hospital Santa Aurora",
        seed_key: "hospital-main"
      ),
      supplier_alpha: upsert_party!(
        tenant: tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor Alpha Serviços Médicos Ltda",
        display_name: "Fornecedor Alpha",
        seed_key: "supplier-alpha"
      ),
      supplier_beta: upsert_party!(
        tenant: tenant,
        kind: "SUPPLIER",
        legal_name: "Fornecedor Beta Apoio Hospitalar Ltda",
        display_name: "Fornecedor Beta",
        seed_key: "supplier-beta"
      ),
      physician_ana: upsert_party!(
        tenant: tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Dra. Ana Carolina Mendes",
        display_name: "Dra. Ana Mendes",
        seed_key: "physician-ana"
      ),
      physician_rafael: upsert_party!(
        tenant: tenant,
        kind: "PHYSICIAN_PF",
        legal_name: "Dr. Rafael Sousa Lima",
        display_name: "Dr. Rafael Lima",
        seed_key: "physician-rafael"
      ),
      clinic: upsert_party!(
        tenant: tenant,
        kind: "LEGAL_ENTITY_PJ",
        legal_name: "Clínica Plantão Integrado SPE Ltda",
        display_name: "Clínica Plantão Integrado",
        seed_key: "clinic-main"
      ),
      fdic: upsert_party!(
        tenant: tenant,
        kind: "FIDC",
        legal_name: "FDIC Nexum Capital Recebíveis I",
        display_name: "FDIC Nexum Capital",
        seed_key: "fdic-main"
      ),
      platform: upsert_party!(
        tenant: tenant,
        kind: "PLATFORM",
        legal_name: "Nexum Capital S.A.",
        display_name: "Nexum Capital",
        seed_key: "platform-main"
      )
    }
  end

  def seed_receivable_kinds!(tenant)
    {
      supplier: ReceivableKind.find_or_create_by!(tenant: tenant, code: "supplier_invoice") do |record|
        record.name = "Fatura de Fornecedor"
        record.source_family = "SUPPLIER"
        record.active = true
      end,
      physician: ReceivableKind.find_or_create_by!(tenant: tenant, code: "physician_shift") do |record|
        record.name = "Plantão Médico"
        record.source_family = "PHYSICIAN"
        record.active = true
      end
    }
  end

  def seed_physicians!(tenant, parties)
    [
      [ parties.fetch(:physician_ana), "Dra. Ana Carolina Mendes", "ana.mendes@demo.nexum.capital", "11987650001", "12345", "SP" ],
      [ parties.fetch(:physician_rafael), "Dr. Rafael Sousa Lima", "rafael.lima@demo.nexum.capital", "11987650002", "54321", "RJ" ]
    ].each do |party, full_name, email, phone, crm_number, crm_state|
      physician = Physician.find_or_initialize_by(tenant: tenant, party: party)
      physician.assign_attributes(
        full_name: full_name,
        email: email,
        phone: phone,
        crm_number: crm_number,
        crm_state: crm_state,
        active: true,
        metadata: { "seed" => true }
      )
      physician.save!
    end
  end

  def seed_physician_memberships!(tenant, parties)
    [
      [ parties.fetch(:physician_ana), "ADMIN" ],
      [ parties.fetch(:physician_rafael), "MEMBER" ]
    ].each do |physician_party, role|
      membership = PhysicianLegalEntityMembership.find_or_initialize_by(
        tenant: tenant,
        physician_party: physician_party,
        legal_entity_party: parties.fetch(:clinic)
      )
      membership.assign_attributes(
        membership_role: role,
        status: "ACTIVE",
        joined_at: 120.days.ago,
        metadata: { "seed" => true }
      )
      membership.save!
    end
  end

  def seed_split_policy!(tenant, parties)
    policy = PhysicianCnpjSplitPolicy.find_or_initialize_by(
      tenant: tenant,
      legal_entity_party: parties.fetch(:clinic),
      scope: "SHARED_CNPJ",
      effective_from: Time.zone.parse("2025-01-01 00:00:00")
    )
    policy.assign_attributes(
      cnpj_share_rate: rate("0.30000000"),
      physician_share_rate: rate("0.70000000"),
      status: "ACTIVE",
      metadata: { "seed" => true }
    )
    policy.save!
  end

  def seed_users!(tenant, parties)
    [
      [ "hospital_admin@demo.nexum.capital", "hospital_admin", parties.fetch(:hospital) ],
      [ "supplier_user@demo.nexum.capital", "supplier_user", parties.fetch(:supplier_alpha) ],
      [ "physician_user@demo.nexum.capital", "physician_pf_user", parties.fetch(:physician_ana) ],
      [ "fdic_user@demo.nexum.capital", "ops_admin", parties.fetch(:fdic) ]
    ].each do |email, role, party|
      user = User.find_or_initialize_by(email_address: email)
      user.tenant = tenant
      user.party = party
      user.role = role
      user.password = PASSWORD
      user.password_confirmation = PASSWORD
      user.save!
    end
  end

  def build_receivable_scenarios!(tenant, parties, kinds)
    scenarios = [
      { code: "SUP-001", kind: :supplier, owner: :supplier_alpha, gross: "18250.25", receivable_status: "PERFORMED" },
      { code: "SUP-002", kind: :supplier, owner: :supplier_beta, gross: "23690.40", receivable_status: "ANTICIPATION_REQUESTED", anticipation_status: "REQUESTED" },
      { code: "SUP-003", kind: :supplier, owner: :supplier_alpha, gross: "31420.10", receivable_status: "FUNDED", anticipation_status: "FUNDED" },
      { code: "SUP-004", kind: :supplier, owner: :supplier_beta, gross: "17490.90", receivable_status: "SETTLED", anticipation_status: "SETTLED" },
      { code: "SUP-005", kind: :supplier, owner: :supplier_alpha, gross: "40220.75", receivable_status: "ANTICIPATION_REQUESTED", anticipation_status: "APPROVED" },
      { code: "SUP-006", kind: :supplier, owner: :supplier_beta, gross: "12990.15", receivable_status: "SETTLED", anticipation_status: "SETTLED" },
      { code: "PHY-001", kind: :physician, physician: :physician_ana, gross: "9880.40", receivable_status: "ANTICIPATION_REQUESTED", anticipation_status: "REQUESTED" },
      { code: "PHY-002", kind: :physician, physician: :physician_rafael, gross: "14330.55", receivable_status: "FUNDED", anticipation_status: "FUNDED" },
      { code: "PHY-003", kind: :physician, physician: :physician_ana, gross: "11110.10", receivable_status: "SETTLED", anticipation_status: "SETTLED" },
      { code: "PHY-004", kind: :physician, physician: :physician_rafael, gross: "20540.90", receivable_status: "SETTLED", anticipation_status: "SETTLED" },
      { code: "PHY-005", kind: :physician, physician: :physician_ana, gross: "12320.60", receivable_status: "PERFORMED" },
      { code: "PHY-006", kind: :physician, physician: :physician_rafael, gross: "16880.00", receivable_status: "ANTICIPATION_REQUESTED", anticipation_status: "APPROVED" }
    ]

    scenarios.each_with_index do |scenario, index|
      build_receivable_scenario!(
        tenant: tenant,
        parties: parties,
        kinds: kinds,
        scenario: scenario,
        index: index
      )
    end
  end

  def build_receivable_scenario!(tenant:, parties:, kinds:, scenario:, index:)
    code = scenario.fetch(:code)
    kind_type = scenario.fetch(:kind)
    kind = kinds.fetch(kind_type)
    gross_amount = money(scenario.fetch(:gross))
    performed_at = BusinessCalendar.time_zone.now - (28 - index).days + 9.hours
    due_at = performed_at + (18 + (index % 7)).days
    cutoff_at = BusinessCalendar.cutoff_at(performed_at.to_date)

    if kind_type == :supplier
      creditor_party = parties.fetch(scenario.fetch(:owner))
      beneficiary_party = creditor_party
      allocated_party = creditor_party
      physician_party = nil
    else
      creditor_party = parties.fetch(:clinic)
      beneficiary_party = parties.fetch(:clinic)
      allocated_party = parties.fetch(:clinic)
      physician_party = parties.fetch(scenario.fetch(:physician))
    end

    receivable = Receivable.find_or_initialize_by(
      tenant: tenant,
      external_reference: "SIM-#{code}"
    )
    receivable.assign_attributes(
      receivable_kind: kind,
      debtor_party: parties.fetch(:hospital),
      creditor_party: creditor_party,
      beneficiary_party: beneficiary_party,
      gross_amount: gross_amount,
      currency: "BRL",
      performed_at: performed_at,
      due_at: due_at,
      cutoff_at: cutoff_at,
      status: scenario.fetch(:receivable_status),
      metadata: { "seed_scenario" => code }
    )
    receivable.save!

    allocation = ReceivableAllocation.find_or_initialize_by(
      tenant: tenant,
      receivable: receivable,
      sequence: 1
    )
    allocation.assign_attributes(
      allocated_party: allocated_party,
      physician_party: physician_party,
      gross_amount: gross_amount,
      tax_reserve_amount: money("0"),
      status: receivable.status == "SETTLED" ? "SETTLED" : "OPEN",
      eligible_for_anticipation: true,
      metadata: { "seed_scenario" => code }
    )
    allocation.save!

    anticipation = nil
    if scenario[:anticipation_status].present?
      anticipation = build_anticipation!(
        tenant: tenant,
        receivable: receivable,
        allocation: allocation,
        requester_party: physician_party || allocated_party,
        scenario_code: code,
        requested_at: performed_at + 2.hours,
        status: scenario.fetch(:anticipation_status)
      )
      build_confirmation_challenges!(tenant: tenant, anticipation: anticipation)
      build_signed_document!(tenant: tenant, receivable: receivable, actor_party: anticipation.requester_party, scenario_code: code, signed_at: anticipation.requested_at + 45.minutes)
    end

    settlement = nil
    if receivable.status == "SETTLED"
      settlement = build_settlement!(
        tenant: tenant,
        receivable: receivable,
        allocation: allocation,
        anticipation: anticipation,
        scenario_code: code
      )
    end

    build_receivable_events!(
      tenant: tenant,
      receivable: receivable,
      anticipation: anticipation,
      settlement: settlement,
      actor_party: physician_party || allocated_party
    )
  end

  def build_anticipation!(tenant:, receivable:, allocation:, requester_party:, scenario_code:, requested_at:, status:)
    requested_amount = money(receivable.gross_amount.to_d * BigDecimal("0.82"))
    discount_rate = rate(BigDecimal("0.0385") + BigDecimal((scenario_code.hash % 7).to_s) / BigDecimal("1000"))
    discount_amount = money(requested_amount * discount_rate)
    net_amount = money(requested_amount - discount_amount)

    anticipation = AnticipationRequest.find_or_initialize_by(
      tenant: tenant,
      idempotency_key: "seed-anticipation-#{scenario_code.downcase}"
    )
    anticipation.assign_attributes(
      receivable: receivable,
      receivable_allocation: allocation,
      requester_party: requester_party,
      requested_amount: requested_amount,
      discount_rate: discount_rate,
      discount_amount: discount_amount,
      net_amount: net_amount,
      status: status,
      channel: "PORTAL",
      requested_at: requested_at,
      settlement_target_date: BusinessCalendar.next_business_day(from: requested_at),
      funded_at: status.in?(%w[FUNDED SETTLED]) ? requested_at + 8.hours : nil,
      settled_at: status == "SETTLED" ? requested_at + 2.days : nil,
      metadata: {
        "seed_scenario" => scenario_code,
        "requested_by" => requester_party.kind
      }
    )
    anticipation.save!
    anticipation
  end

  def build_confirmation_challenges!(tenant:, anticipation:)
    status = anticipation.status.in?(%w[APPROVED FUNDED SETTLED]) ? "VERIFIED" : "PENDING"
    consumed_at = status == "VERIFIED" ? anticipation.requested_at + 30.minutes : nil

    %w[EMAIL WHATSAPP].each do |channel|
      challenge = AuthChallenge.find_or_initialize_by(
        id: seed_uuid("challenge-#{anticipation.id}-#{channel.downcase}")
      )
      challenge.assign_attributes(
        tenant: tenant,
        actor_party: anticipation.requester_party,
        purpose: "ANTICIPATION_CONFIRMATION",
        delivery_channel: channel,
        destination_masked: channel == "EMAIL" ? "d***@demo.nexum.capital" : "+55*******123",
        code_digest: Digest::SHA256.hexdigest("#{anticipation.id}-#{channel}-seed-code"),
        status: status,
        attempts: 0,
        max_attempts: 5,
        expires_at: anticipation.requested_at + 45.minutes,
        consumed_at: consumed_at,
        request_id: "seed-req-#{anticipation.id}-#{channel.downcase}",
        target_type: "AnticipationRequest",
        target_id: anticipation.id,
        metadata: {
          "seed" => true,
          "scenario" => anticipation.metadata.fetch("seed_scenario")
        }
      )
      challenge.save!
    end
  end

  def build_signed_document!(tenant:, receivable:, actor_party:, scenario_code:, signed_at:)
    document = Document.find_or_initialize_by(id: seed_uuid("document-#{scenario_code.downcase}"))
    document.assign_attributes(
      tenant: tenant,
      receivable: receivable,
      actor_party: actor_party,
      document_type: "ASSIGNMENT_CONTRACT",
      signature_method: "OWN_PLATFORM_CONFIRMATION",
      status: "SIGNED",
      sha256: Digest::SHA256.hexdigest("document-#{scenario_code.downcase}"),
      storage_key: "contracts/#{scenario_code.downcase}.pdf",
      signed_at: signed_at,
      metadata: {
        "seed_scenario" => scenario_code,
        "language" => "pt-BR"
      }
    )
    document.save!

    event = DocumentEvent.find_or_initialize_by(id: seed_uuid("document-event-#{scenario_code.downcase}"))
    event.assign_attributes(
      tenant: tenant,
      document: document,
      receivable: receivable,
      actor_party: actor_party,
      event_type: "DOCUMENT_SIGNED",
      occurred_at: signed_at,
      request_id: "seed-doc-#{scenario_code.downcase}",
      payload: {
        "seed_scenario" => scenario_code,
        "document_type" => document.document_type
      }
    )
    event.save!
  end

  def build_settlement!(tenant:, receivable:, allocation:, anticipation:, scenario_code:)
    paid_at = receivable.due_at - 1.day
    paid_amount = receivable.gross_amount.to_d

    cnpj_share_rate = allocation.metadata.dig("cnpj_split", "cnpj_share_rate").presence || "0"
    cnpj_amount = money(paid_amount * BigDecimal(cnpj_share_rate.to_s))
    beneficiary_pool = money(paid_amount - cnpj_amount)

    obligation = anticipation ? money(anticipation.requested_amount.to_d + anticipation.discount_amount.to_d) : money("0")
    fdic_before = obligation
    fdic_amount = money([ beneficiary_pool.to_d, fdic_before.to_d ].min)
    beneficiary_amount = money(beneficiary_pool.to_d - fdic_amount.to_d)
    fdic_after = money(fdic_before.to_d - fdic_amount.to_d)

    settlement = ReceivablePaymentSettlement.find_or_initialize_by(
      tenant: tenant,
      payment_reference: "seed-payment-#{scenario_code.downcase}"
    )
    settlement.assign_attributes(
      receivable: receivable,
      receivable_allocation: allocation,
      paid_amount: money(paid_amount),
      cnpj_amount: cnpj_amount,
      fdic_amount: fdic_amount,
      beneficiary_amount: beneficiary_amount,
      fdic_balance_before: fdic_before,
      fdic_balance_after: fdic_after,
      paid_at: paid_at,
      request_id: "seed-settlement-#{scenario_code.downcase}",
      idempotency_key: "seed-settlement-#{scenario_code.downcase}",
      metadata: {
        "seed_scenario" => scenario_code
      }
    )
    settlement.save!

    if anticipation && fdic_amount.to_d.positive?
      entry = AnticipationSettlementEntry.find_or_initialize_by(id: seed_uuid("settlement-entry-#{scenario_code.downcase}"))
      entry.assign_attributes(
        tenant: tenant,
        receivable_payment_settlement: settlement,
        anticipation_request: anticipation,
        settled_amount: fdic_amount,
        settled_at: paid_at,
        metadata: {
          "seed_scenario" => scenario_code
        }
      )
      entry.save!
    end

    settlement
  end

  def build_receivable_events!(tenant:, receivable:, anticipation:, settlement:, actor_party:)
    return if ReceivableEvent.where(tenant: tenant, receivable: receivable).exists?

    timeline = []
    timeline << [ "RECEIVABLE_PERFORMED", receivable.performed_at, { "gross_amount" => receivable.gross_amount.to_s("F") } ]
    if anticipation
      timeline << [ "ANTICIPATION_REQUESTED", anticipation.requested_at, { "anticipation_request_id" => anticipation.id } ]
      timeline << [ "ANTICIPATION_CONFIRMATION_CHALLENGES_ISSUED", anticipation.requested_at + 10.minutes, { "channels" => %w[EMAIL WHATSAPP] } ]
      timeline << [ "ANTICIPATION_CONFIRMED", anticipation.requested_at + 30.minutes, { "confirmation_channels" => %w[EMAIL WHATSAPP] } ] if anticipation.status.in?(%w[APPROVED FUNDED SETTLED])
      timeline << [ "ANTICIPATION_FUNDED", anticipation.funded_at || (anticipation.requested_at + 8.hours), { "status" => anticipation.status } ] if anticipation.status.in?(%w[FUNDED SETTLED])
    end
    if settlement
      timeline << [ "RECEIVABLE_PAYMENT_SETTLED", settlement.paid_at, { "payment_reference" => settlement.payment_reference } ]
    end

    previous_hash = nil
    timeline.each_with_index do |(event_type, occurred_at, payload), index|
      sequence = index + 1
      request_id = "seed-receivable-#{receivable.id}-#{sequence}"
      event_hash = Digest::SHA256.hexdigest(
        [
          receivable.id,
          sequence,
          event_type,
          occurred_at.utc.iso8601(6),
          request_id,
          previous_hash,
          payload.to_json
        ].join("|")
      )

      event = ReceivableEvent.find_or_initialize_by(
        id: seed_uuid("receivable-event-#{receivable.id}-#{sequence}")
      )
      event.assign_attributes(
        tenant: tenant,
        receivable: receivable,
        sequence: sequence,
        event_type: event_type,
        actor_party: actor_party,
        actor_role: "seed_runner",
        occurred_at: occurred_at,
        request_id: request_id,
        prev_hash: previous_hash,
        event_hash: event_hash,
        payload: payload
      )
      event.save!
      previous_hash = event_hash
    end
  end

  def seed_daily_statistics!(tenant, kinds)
    start_date = 13.days.ago.to_date
    end_date = Time.zone.today

    (start_date..end_date).each do |date|
      kinds.each_value do |kind|
        receivables_for_day = Receivable.where(
          tenant: tenant,
          receivable_kind: kind
        ).where("performed_at::date = ?", date)

        anticipations_for_day = AnticipationRequest
          .joins(:receivable)
          .where(tenant: tenant, receivables: { receivable_kind_id: kind.id })
          .where("anticipation_requests.requested_at::date = ?", date)

        settlements_for_day = ReceivablePaymentSettlement
          .joins(:receivable)
          .where(tenant: tenant, receivables: { receivable_kind_id: kind.id })
          .where("receivable_payment_settlements.paid_at::date = ?", date)

        entry = ReceivableDailyStatistic.find_or_initialize_by(
          tenant: tenant,
          stat_date: date,
          receivable_kind: kind,
          metric_scope: "GLOBAL",
          scope_party: nil
        )
        entry.assign_attributes(
          receivable_count: receivables_for_day.count,
          gross_amount: money(receivables_for_day.sum(:gross_amount)),
          anticipated_count: anticipations_for_day.count,
          anticipated_amount: money(anticipations_for_day.sum(:requested_amount)),
          settled_count: settlements_for_day.count,
          settled_amount: money(settlements_for_day.sum(:paid_amount)),
          last_computed_at: Time.current
        )
        entry.save!
      end
    end
  end

  def upsert_party!(tenant:, kind:, legal_name:, display_name:, seed_key:)
    document_number = kind == "PHYSICIAN_PF" ? valid_cpf(seed_key) : valid_cnpj(seed_key)

    party = Party.find_or_initialize_by(
      tenant: tenant,
      kind: kind,
      document_number: document_number
    )
    party.assign_attributes(
      legal_name: legal_name,
      display_name: display_name,
      active: true,
      metadata: {
        "seed_key" => seed_key,
        "locale" => "pt-BR"
      }
    )
    party.save!
    party
  end

  def valid_cpf(seed)
    base = numeric_seed(seed, size: 9)
    base = [ 1, 2, 3, 4, 5, 6, 7, 8, 9 ] if base.uniq.one?

    first_check = cpf_check_digit(base, 10)
    second_check = cpf_check_digit(base + [ first_check ], 11)

    (base + [ first_check, second_check ]).join
  end

  def valid_cnpj(seed)
    base = numeric_seed(seed, size: 12)
    base = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2 ] if base.uniq.one?

    first_check = cnpj_check_digit(base, [ 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])
    second_check = cnpj_check_digit(base + [ first_check ], [ 6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])

    (base + [ first_check, second_check ]).join
  end

  def numeric_seed(seed, size:)
    source = Digest::SHA256.hexdigest(seed.to_s).chars.map { |char| char.to_i(16) % 10 }
    Array.new(size) { |index| source[index % source.length] }
  end

  def cpf_check_digit(values, weight_start)
    sum = values.each_with_index.sum { |value, index| value * (weight_start - index) }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end

  def cnpj_check_digit(values, weights)
    sum = values.each_with_index.sum { |value, index| value * weights[index] }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end

  def money(value)
    FinancialRounding.money(value)
  end

  def rate(value)
    FinancialRounding.rate(value)
  end

  def seed_uuid(key)
    hex = Digest::SHA256.hexdigest(key.to_s)[0, 32]
    [
      hex[0, 8],
      hex[8, 4],
      hex[12, 4],
      hex[16, 4],
      hex[20, 12]
    ].join("-")
  end

  def with_tenant_context(tenant_id:, actor_id: nil, role: nil)
    set_db_context("app.tenant_id", tenant_id)
    set_db_context("app.actor_id", actor_id)
    set_db_context("app.role", role)
    yield
  ensure
    set_db_context("app.tenant_id", nil)
    set_db_context("app.actor_id", nil)
    set_db_context("app.role", nil)
  end

  def set_db_context(key, value)
    connection = ActiveRecord::Base.connection
    connection.execute(
      "SELECT set_config(#{connection.quote(key)}, #{connection.quote(value.to_s)}, false)"
    )
  end
end

DemoSeeds.run!
