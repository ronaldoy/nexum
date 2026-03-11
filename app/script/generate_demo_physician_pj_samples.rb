#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "digest"
require "securerandom"

module DemoPhysicianPjSampleGenerator
  module_function

  TARGET_LOANS = Integer(ENV.fetch("TARGET_PJ_LOANS", "8"))
  TARGET_COMPANIES = Integer(ENV.fetch("TARGET_PJ_COMPANIES", "4"))
  TENANT_SLUG = ENV.fetch("TENANT_SLUG", "demo-br")
  RECEIVABLE_KIND_CODE = "physician_shift"
  BULK_REF_PREFIX = "BULK-PJ"
  REQUESTED_RATIO = BigDecimal("0.84")
  RATE_BASE = BigDecimal("0.0320")
  COMPANY_IDENTITIES = [
    { display_name: "Martins Medicina Integrada", legal_name: "Martins Medicina Integrada Ltda" },
    { display_name: "Teixeira Plantoes Medicos", legal_name: "Teixeira Plantonistas Associados Ltda" },
    { display_name: "Oliveira Clinica Medica", legal_name: "Oliveira Clinica Medica e Plantao Ltda" },
    { display_name: "Freitas Servicos Medicos", legal_name: "Freitas Servicos Medicos Hospitalares Ltda" },
    { display_name: "Campos Atendimento Medico", legal_name: "Campos Atendimento Medico Especializado Ltda" },
    { display_name: "Silva Medicina Intensiva", legal_name: "Silva Medicina Intensiva Ltda" }
  ].freeze

  def run!
    tenant = Tenant.find_by!(slug: TENANT_SLUG)
    receivable_kind = ReceivableKind.find_by!(tenant: tenant, code: RECEIVABLE_KIND_CODE)
    hospitals = Party.where(tenant: tenant, kind: "HOSPITAL").order(:created_at).to_a
    physicians = Physician.where(tenant: tenant).includes(:party).order(:created_at).limit(TARGET_COMPANIES).to_a

    raise "Need at least #{TARGET_COMPANIES} physicians to generate PJ samples" if physicians.size < TARGET_COMPANIES

    companies = ensure_companies!(tenant:, physicians:)
    existing_loans = AnticipationRequest.where(tenant: tenant).joins(:requester_party).where(parties: { kind: "LEGAL_ENTITY_PJ" }).where("anticipation_requests.metadata ->> 'bulk_demo_pj' = 'true'").count
    loans_to_create = [ TARGET_LOANS - existing_loans, 0 ].max
    created_loans = create_loans!(tenant:, receivable_kind:, hospitals:, companies:, count: loans_to_create)

    puts(
      {
        tenant: tenant.slug,
        pj_companies: companies.size,
        created_pj_loans: created_loans,
        total_pj_loans: AnticipationRequest.where(tenant: tenant).joins(:requester_party).where(parties: { kind: "LEGAL_ENTITY_PJ" }).count
      }.inspect
    )
  end

  def ensure_companies!(tenant:, physicians:)
    physicians.first(TARGET_COMPANIES).each_with_index.map do |physician, index|
      identity = COMPANY_IDENTITIES.fetch(index % COMPANY_IDENTITIES.size)
      cnpj = cnpj_for(index + 1)
      company = Party.find_or_initialize_by(tenant: tenant, document_number: cnpj)
      company.assign_attributes(
        kind: "LEGAL_ENTITY_PJ",
        display_name: identity.fetch(:display_name),
        legal_name: identity.fetch(:legal_name),
        document_type: "CNPJ",
        metadata: { "bulk_demo_pj" => true, "sequence" => index + 1 }
      )
      company.save!

      membership = PhysicianLegalEntityMembership.find_or_initialize_by(
        tenant: tenant,
        physician_party: physician.party,
        legal_entity_party: company
      )
      membership.assign_attributes(
        membership_role: index.even? ? "ADMIN" : "MEMBER",
        status: "ACTIVE",
        joined_at: 60.days.ago,
        metadata: { "bulk_demo_pj" => true }
      )
      membership.save!

      { company: company, physician_party: physician.party }
    end
  end

  def create_loans!(tenant:, receivable_kind:, hospitals:, companies:, count:)
    return 0 if count.zero?

    created = 0
    next_ref = next_bulk_reference_index(tenant)

    ActiveRecord::Base.transaction do
      count.times do |index|
        company_row = companies[index % companies.size]
        company = company_row.fetch(:company)
        physician_party = company_row.fetch(:physician_party)
        hospital = hospitals[index % hospitals.size]
        status = anticipation_status_for(index)
        gross_amount = gross_amount_for(index)
        requested_amount = FinancialRounding.money(gross_amount * REQUESTED_RATIO)
        discount_rate = RATE_BASE + (BigDecimal((index % 5).to_s) / BigDecimal("1000"))
        discount_amount = FinancialRounding.money(requested_amount * discount_rate)
        net_amount = FinancialRounding.money(requested_amount - discount_amount)
        performed_at = Time.zone.parse("2026-02-05 09:00:00") + (index * 8).hours
        requested_at = performed_at + 90.minutes
        due_at = performed_at + (24 + (index % 7)).days
        reference = format("%s-%03d", BULK_REF_PREFIX, next_ref + index)

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: receivable_kind,
          debtor_party: hospital,
          creditor_party: company,
          beneficiary_party: company,
          external_reference: reference,
          gross_amount: gross_amount,
          currency: "BRL",
          status: receivable_status_for(status),
          performed_at: performed_at,
          due_at: due_at,
          cutoff_at: BusinessCalendar.cutoff_at(performed_at.to_date),
          metadata: { "bulk_demo_pj" => true, "reference" => reference }
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: company,
          physician_party: physician_party,
          gross_amount: gross_amount,
          tax_reserve_amount: FinancialRounding.money(0),
          status: status == "SETTLED" ? "SETTLED" : "OPEN",
          eligible_for_anticipation: true,
          metadata: { "bulk_demo_pj" => true, "reference" => reference }
        )

        anticipation = AnticipationRequest.create!(
          tenant: tenant,
          receivable: receivable,
          receivable_allocation: allocation,
          requester_party: company,
          idempotency_key: SecureRandom.uuid,
          requested_amount: requested_amount,
          discount_rate: discount_rate,
          discount_amount: discount_amount,
          net_amount: net_amount,
          status: status,
          channel: "PORTAL",
          requested_at: requested_at,
          settlement_target_date: BusinessCalendar.next_business_day(from: requested_at),
          funded_at: status.in?(%w[FUNDED SETTLED]) ? requested_at + 6.hours : nil,
          settled_at: status == "SETTLED" ? requested_at + 2.days : nil,
          metadata: {
            "bulk_demo_pj" => true,
            "reference" => reference,
            "requested_by" => "LEGAL_ENTITY_PJ"
          }
        )

        if status != "REQUESTED"
          Document.create!(
            tenant: tenant,
            receivable: receivable,
            actor_party: company,
            document_type: "ASSIGNMENT_CONTRACT",
            signature_method: "OWN_PLATFORM_CONFIRMATION",
            status: "SIGNED",
            sha256: Digest::SHA256.hexdigest("bulk-demo-pj-document-#{reference}"),
            storage_key: "contracts/#{reference.downcase}.pdf",
            signed_at: requested_at + 30.minutes,
            metadata: { "bulk_demo_pj" => true, "reference" => reference }
          )
        end

        if status == "SETTLED"
          settled_amount = FinancialRounding.money(requested_amount + discount_amount)
          settlement = ReceivablePaymentSettlement.create!(
            tenant: tenant,
            receivable: receivable,
            receivable_allocation: allocation,
            paid_amount: settled_amount,
            cnpj_amount: FinancialRounding.money(0),
            fidc_amount: settled_amount,
            beneficiary_amount: FinancialRounding.money(0),
            fidc_balance_before: settled_amount,
            fidc_balance_after: FinancialRounding.money(0),
            paid_at: requested_at + 2.days,
            payment_reference: "bulk-pj-#{reference.downcase}",
            idempotency_key: SecureRandom.uuid
          )

          AnticipationSettlementEntry.create!(
            tenant: tenant,
            receivable_payment_settlement: settlement,
            anticipation_request: anticipation,
            settled_amount: settled_amount,
            settled_at: requested_at + 2.days,
            metadata: { "bulk_demo_pj" => true, "reference" => reference }
          )
        end

        created += 1
      end
    end

    created
  end

  def next_bulk_reference_index(tenant)
    existing = Receivable.where(tenant: tenant).where("external_reference LIKE ?", "#{BULK_REF_PREFIX}-%").pluck(:external_reference)
    return 1 if existing.empty?

    existing.filter_map { |reference| reference.split("-").last.to_i if reference.start_with?("#{BULK_REF_PREFIX}-") }.max.to_i + 1
  end

  def anticipation_status_for(index)
    %w[REQUESTED APPROVED FUNDED SETTLED][index % 4]
  end

  def receivable_status_for(anticipation_status)
    case anticipation_status
    when "REQUESTED", "APPROVED"
      "ANTICIPATION_REQUESTED"
    when "FUNDED"
      "FUNDED"
    when "SETTLED"
      "SETTLED"
    else
      "PERFORMED"
    end
  end

  def gross_amount_for(index)
    cents = 165_000 + ((index * 271) % 38_000)
    BigDecimal(cents.to_s) / 100
  end

  def cnpj_for(sequence)
    base_digits = format("%012d", 23_000_000_000 + sequence).chars.map(&:to_i)
    first_digit = cnpj_check_digit(base_digits, [ 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])
    second_digit = cnpj_check_digit(base_digits + [ first_digit ], [ 6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2 ])
    (base_digits + [ first_digit, second_digit ]).join
  end

  def cnpj_check_digit(digits, weights)
    sum = digits.each_with_index.sum { |digit, index| digit * weights[index] }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end
end

DemoPhysicianPjSampleGenerator.run!
