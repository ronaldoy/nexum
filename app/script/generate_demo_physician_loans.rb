#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "digest"
require "securerandom"

module DemoPhysicianLoanGenerator
  module_function

  TARGET_LOANS = Integer(ENV.fetch("TARGET_LOANS", "250"))
  TARGET_PHYSICIANS = Integer(ENV.fetch("TARGET_PHYSICIANS", "50"))
  TENANT_SLUG = ENV.fetch("TENANT_SLUG", "demo-br")
  RECEIVABLE_KIND_CODE = "physician_shift"
  BULK_REF_PREFIX = "BULK-PHY"
  REQUESTED_RATIO = BigDecimal("0.84")
  RATE_BASE = BigDecimal("0.0310")
  RATE_SPREAD = BigDecimal("0.0080")
  MALE_GIVEN_NAMES = %w[
    Andre
    Bruno
    Caio
    Daniel
    Eduardo
    Felipe
    Gabriel
    Henrique
    Joao
    Leonardo
    Lucas
    Marcelo
    Mateus
    Pedro
    Rafael
    Ricardo
    Thiago
    Vinicius
  ].freeze
  FEMALE_GIVEN_NAMES = %w[
    Ana
    Beatriz
    Camila
    Carolina
    Daniela
    Fernanda
    Gabriela
    Helena
    Isabela
    Juliana
    Larissa
    Mariana
    Natalia
    Patricia
    Renata
    Sofia
    Tatiana
    Valeria
  ].freeze
  MALE_MIDDLE_NAMES = %w[
    Augusto
    Cesar
    Eduardo
    Felipe
    Henrique
    Jose
    Luis
    Miguel
    Paulo
    Victor
  ].freeze
  FEMALE_MIDDLE_NAMES = %w[
    Carolina
    Cristina
    Eduarda
    Fernanda
    Helena
    Luiza
    Maria
    Paula
    Regina
    Vitoria
  ].freeze
  SURNAMES = %w[
    Almeida
    Andrade
    Araujo
    Barbosa
    Barros
    Campos
    Cardoso
    Carvalho
    Castro
    Costa
    Dias
    Duarte
    Fernandes
    Ferreira
    Freitas
    Gomes
    Lima
    Martins
    Melo
    Mendes
    Moraes
    Moreira
    Nascimento
    Oliveira
    Pereira
    Ribeiro
    Rocha
    Santana
    Santos
    Silva
    Soares
    Souza
    Teixeira
  ].freeze

  def run!
    tenant = Tenant.find_by!(slug: TENANT_SLUG)
    receivable_kind = ReceivableKind.find_by!(tenant: tenant, code: RECEIVABLE_KIND_CODE)
    clinic = legal_entity_clinic_for!(tenant)
    hospitals = Party.where(tenant: tenant, kind: "HOSPITAL").order(:created_at).to_a

    existing_requester_ids = AnticipationRequest.where(tenant: tenant).distinct.pluck(:requester_party_id)
    physician_pool = Party.where(tenant: tenant, kind: "PHYSICIAN_PF", id: existing_requester_ids).order(:created_at).to_a

    physicians_needed = [ TARGET_PHYSICIANS - physician_pool.size, 0 ].max
    created_physicians = create_physicians!(tenant:, clinic:, count: physicians_needed)
    normalize_bulk_physicians!(tenant:)
    physician_pool.concat(created_physicians)
    physician_pool = physician_pool.first(TARGET_PHYSICIANS)

    current_loans = AnticipationRequest.where(tenant: tenant).count
    loans_to_create = [ TARGET_LOANS - current_loans, 0 ].max

    if loans_to_create.zero?
      puts({ tenant: tenant.slug, created_physicians: created_physicians.size, created_loans: 0, total_loans: current_loans, distinct_requesters: distinct_requesters_count(tenant) }.inspect)
      return
    end

    created_loans = create_loans!(
      tenant:,
      receivable_kind:,
      clinic:,
      hospitals:,
      physician_pool:,
      count: loans_to_create
    )

    puts(
      {
        tenant: tenant.slug,
        created_physicians: created_physicians.size,
        created_loans: created_loans,
        total_loans: AnticipationRequest.where(tenant: tenant).count,
        distinct_requesters: distinct_requesters_count(tenant)
      }.inspect
    )
  end

  def create_physicians!(tenant:, clinic:, count:)
    created = []
    starting_index = Party.where(tenant: tenant, kind: "PHYSICIAN_PF").count

    count.times do |offset|
      sequence = starting_index + offset + 1
      cpf = cpf_for(sequence)
      party = Party.find_or_initialize_by(tenant: tenant, document_number: cpf)
      identity = physician_identity(sequence)

      party.assign_attributes(
        kind: "PHYSICIAN_PF",
        display_name: identity.fetch(:display_name),
        legal_name: identity.fetch(:legal_name),
        document_type: "CPF",
        metadata: metadata_with_bulk_sequence(party.metadata, sequence)
      )
      party.save!

      physician = Physician.find_or_initialize_by(tenant: tenant, party: party)
      physician.assign_attributes(
        full_name: identity.fetch(:full_name),
        email: identity.fetch(:email),
        phone: format("11988%06d", sequence),
        crm_number: format("%05d", 70_000 + sequence),
        crm_state: BrazilianStates::ABBREVIATIONS[sequence % BrazilianStates::ABBREVIATIONS.size],
        active: physician.has_attribute?(:active) ? true : physician[:active]
      )
      physician.save!

      membership = PhysicianLegalEntityMembership.find_or_initialize_by(
        tenant: tenant,
        physician_party: party,
        legal_entity_party: clinic
      )
      membership.assign_attributes(
        membership_role: sequence.even? ? "MEMBER" : "ADMIN",
        status: "ACTIVE",
        joined_at: 90.days.ago,
        metadata: { "bulk_demo" => true }
      )
      membership.save!

      created << party
    end

    created
  end

  def normalize_bulk_physicians!(tenant:)
    parties = Party.where(tenant: tenant, kind: "PHYSICIAN_PF").order(:created_at).to_a
    bulk_parties = parties.select do |party|
      metadata = safe_metadata(party.metadata)
      metadata["bulk_demo"] || party.display_name.to_s.start_with?("Dr Demo ")
    end
    return if bulk_parties.empty?

    physicians_by_party_id = Physician.where(tenant: tenant, party_id: bulk_parties.map(&:id)).index_by(&:party_id)

    bulk_parties.each_with_index do |party, index|
      metadata = safe_metadata(party.metadata)
      sequence = metadata["sequence"].to_i
      sequence = index + 1 if sequence <= 0
      identity = physician_identity(sequence)

      party.update!(
        display_name: identity.fetch(:display_name),
        legal_name: identity.fetch(:legal_name),
        metadata: metadata_with_bulk_sequence(metadata, sequence)
      )

      physician = physicians_by_party_id[party.id]
      next unless physician

      physician.update!(
        full_name: identity.fetch(:full_name),
        email: identity.fetch(:email),
        active: physician.has_attribute?(:active) ? true : physician[:active]
      )
    end
  end

  def create_loans!(tenant:, receivable_kind:, clinic:, hospitals:, physician_pool:, count:)
    raise "Need at least one physician in pool" if physician_pool.empty?

    created = 0
    next_ref = next_bulk_reference_index(tenant)

    ActiveRecord::Base.transaction do
      count.times do |index|
        physician = physician_pool[index % physician_pool.size]
        hospital = hospitals[index % hospitals.size]
        status = anticipation_status_for(index)
        receivable_status = receivable_status_for(status)
        gross_amount = gross_amount_for(index)
        requested_amount = FinancialRounding.money(gross_amount * REQUESTED_RATIO)
        discount_rate = discount_rate_for(index)
        discount_amount = FinancialRounding.money(requested_amount * discount_rate)
        net_amount = FinancialRounding.money(requested_amount - discount_amount)
        performed_at = Time.zone.parse("2026-02-01 09:00:00") + (index * 6).hours
        requested_at = performed_at + 2.hours
        due_at = performed_at + (21 + (index % 9)).days
        reference = format("%s-%03d", BULK_REF_PREFIX, next_ref + index)

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: receivable_kind,
          debtor_party: hospital,
          creditor_party: clinic,
          beneficiary_party: clinic,
          external_reference: reference,
          gross_amount: gross_amount,
          currency: "BRL",
          status: receivable_status,
          performed_at: performed_at,
          due_at: due_at,
          cutoff_at: BusinessCalendar.cutoff_at(performed_at.to_date),
          metadata: { "bulk_demo" => true, "reference" => reference }
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: clinic,
          physician_party: physician,
          gross_amount: gross_amount,
          tax_reserve_amount: FinancialRounding.money(0),
          status: status == "SETTLED" ? "SETTLED" : "OPEN",
          eligible_for_anticipation: true,
          metadata: { "bulk_demo" => true, "reference" => reference }
        )

        anticipation = AnticipationRequest.create!(
          tenant: tenant,
          receivable: receivable,
          receivable_allocation: allocation,
          requester_party: physician,
          idempotency_key: SecureRandom.uuid,
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
          metadata: { "bulk_demo" => true, "reference" => reference }
        )

        if status != "REQUESTED"
          Document.create!(
            tenant: tenant,
            receivable: receivable,
            actor_party: physician,
            document_type: "ASSIGNMENT_CONTRACT",
            signature_method: "OWN_PLATFORM_CONFIRMATION",
            status: "SIGNED",
            sha256: Digest::SHA256.hexdigest("bulk-demo-document-#{reference}"),
            storage_key: "contracts/#{reference.downcase}.pdf",
            signed_at: requested_at + 45.minutes,
            metadata: { "bulk_demo" => true, "reference" => reference }
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
            fdic_amount: settled_amount,
            beneficiary_amount: FinancialRounding.money(0),
            fdic_balance_before: settled_amount,
            fdic_balance_after: FinancialRounding.money(0),
            paid_at: requested_at + 2.days,
            payment_reference: "bulk-#{reference.downcase}",
            idempotency_key: SecureRandom.uuid
          )

          AnticipationSettlementEntry.create!(
            tenant: tenant,
            receivable_payment_settlement: settlement,
            anticipation_request: anticipation,
            settled_amount: settled_amount,
            settled_at: requested_at + 2.days,
            metadata: { "bulk_demo" => true, "reference" => reference }
          )
        end

        created += 1
      end
    end

    created
  end

  def distinct_requesters_count(tenant)
    AnticipationRequest
      .where(tenant: tenant)
      .joins("INNER JOIN parties requester_parties ON requester_parties.id = anticipation_requests.requester_party_id")
      .where("requester_parties.kind = ?", "PHYSICIAN_PF")
      .distinct
      .count(:requester_party_id)
  end

  def legal_entity_clinic_for!(tenant)
    Party.where(tenant: tenant, kind: "LEGAL_ENTITY_PJ").find do |party|
      party.display_name.to_s.include?("Plant")
    end || raise("Clinic party not found for #{tenant.slug}")
  end

  def next_bulk_reference_index(tenant)
    existing = Receivable.where(tenant: tenant).where("external_reference LIKE ?", "#{BULK_REF_PREFIX}-%").pluck(:external_reference)
    return 1 if existing.empty?

    existing.filter_map { |reference| reference.split("-").last.to_i if reference.start_with?("#{BULK_REF_PREFIX}-") }.max.to_i + 1
  end

  def gross_amount_for(index)
    cents = 150_000 + ((index * 193) % 45_000)
    BigDecimal(cents.to_s) / 100
  end

  def discount_rate_for(index)
    RATE_BASE + (BigDecimal((index % 6).to_s) / BigDecimal("1000"))
  end

  def physician_identity(sequence)
    gender = sequence.even? ? :female : :male
    given_names = gender == :female ? FEMALE_GIVEN_NAMES : MALE_GIVEN_NAMES
    middle_names = gender == :female ? FEMALE_MIDDLE_NAMES : MALE_MIDDLE_NAMES
    sequence_index = sequence - 1
    first_name = given_names[sequence_index % given_names.length]
    middle_name = middle_names[(sequence_index / given_names.length) % middle_names.length]
    surname_one = SURNAMES[(sequence_index * 3) % SURNAMES.length]
    surname_two = SURNAMES[((sequence_index * 3) + 11) % SURNAMES.length]
    surname_two = SURNAMES[((sequence_index * 3) + 17) % SURNAMES.length] if surname_one == surname_two
    full_name = [ first_name, middle_name, surname_one, surname_two ].join(" ")
    prefix = gender == :female ? "Dra." : "Dr."

    {
      display_name: "#{prefix} #{first_name} #{surname_two}",
      legal_name: full_name,
      full_name: full_name,
      email: "#{full_name.parameterize(separator: '.')}@avertacapital.com.br"
    }
  end

  def safe_metadata(value)
    value.is_a?(Hash) ? value.deep_dup : {}
  end

  def metadata_with_bulk_sequence(existing_metadata, sequence)
    safe_metadata(existing_metadata).merge(
      "bulk_demo" => true,
      "sequence" => sequence
    )
  end

  def anticipation_status_for(index)
    %w[REQUESTED APPROVED FUNDED SETTLED APPROVED FUNDED][index % 6]
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

  def cpf_for(sequence)
    base_digits = format("%09d", 100_000_000 + sequence).chars.map(&:to_i)
    first_digit = cpf_check_digit(base_digits, 10)
    second_digit = cpf_check_digit(base_digits + [ first_digit ], 11)
    (base_digits + [ first_digit, second_digit ]).join
  end

  def cpf_check_digit(digits, weight_start)
    sum = digits.each_with_index.sum { |digit, index| digit * (weight_start - index) }
    remainder = sum % 11
    remainder < 2 ? 0 : 11 - remainder
  end
end

DemoPhysicianLoanGenerator.run!
