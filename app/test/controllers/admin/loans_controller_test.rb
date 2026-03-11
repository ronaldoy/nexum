require "rack/test"
require "tempfile"

require "test_helper"

module Admin
  class LoansControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
        @hospital = Party.create!(
          tenant: @tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital Pipeline",
          document_number: valid_cnpj_from_seed("loan-hospital")
        )
        @supplier = Party.create!(
          tenant: @tenant,
          kind: "SUPPLIER",
          legal_name: "Fornecedor Pipeline",
          document_number: valid_cnpj_from_seed("loan-supplier")
        )
        Party.create!(
          tenant: @tenant,
          kind: "FIDC",
          legal_name: "FIDC Pipeline",
          document_number: valid_cnpj_from_seed("loan-fidc")
        )
        @receivable_kind = ReceivableKind.create!(
          tenant: @tenant,
          code: "supplier_invoice_cockpit",
          name: "Fatura fornecedor cockpit",
          source_family: "SUPPLIER"
        )
      end
    end

    test "ops admin originates and manages a loan through the cockpit" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      post admin_loans_path, params: {
        loan: {
          loan_name: "Operacao teste",
          external_reference: "AVR-TEST-001",
          receivable_kind_id: @receivable_kind.id,
          debtor_party_id: @hospital.id,
          counterparty_id: @supplier.id,
          gross_amount: "1500.00",
          requested_amount: "1350.00",
          discount_rate: "0.04500000",
          performed_at: Time.current.strftime("%Y-%m-%dT%H:%M"),
          due_at: 45.days.from_now.strftime("%Y-%m-%dT%H:%M")
        }
      }

      loan = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        AnticipationRequest.order(created_at: :desc).first
      end

      assert_redirected_to admin_loan_path(loan)

      patch approve_admin_loan_path(loan)
      assert_redirected_to admin_loan_path(loan)

      patch fund_admin_loan_path(loan)
      assert_redirected_to admin_loan_path(loan)

      document_content = "loan-doc-content"
      post record_document_admin_loan_path(loan), params: {
        document: {
          document_type: "ASSIGNMENT_CONTRACT",
          file: uploaded_pdf(filename: "loan-doc.pdf", content: document_content),
          provider_envelope_id: "env-123",
          signed_at: Time.current.strftime("%Y-%m-%dT%H:%M")
        }
      }
      assert_redirected_to admin_loan_path(loan)

      post record_profitability_admin_loan_path(loan), params: {
        profitability: {
          entry_kind: "INCOME",
          category: "fee_income",
          amount: "12.40",
          occurred_on: Date.current.iso8601,
          note: "Receita manual"
        }
      }
      assert_redirected_to admin_loan_path(loan)

      post settle_admin_loan_path(loan), params: {
        settlement: {
          paid_amount: "1500.00",
          paid_at: Time.current.strftime("%Y-%m-%dT%H:%M"),
          payment_reference: "PAY-LOAN-001"
        }
      }
      assert_redirected_to admin_loan_path(loan)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        loan.reload
        document = loan.receivable.documents.order(created_at: :desc).first

        assert_equal "SETTLED", loan.status
        assert loan.receivable.documents.exists?
        assert_equal "ADMIN_IMPORTED_EVIDENCE", document.signature_method
        assert_equal @ops_user.party_id, document.actor_party_id
        assert_equal Digest::SHA256.hexdigest(document_content), document.sha256
        assert document.file.attached?
        assert_equal 1, DocumentEvent.where(tenant_id: @tenant.id, document_id: document.id, event_type: "DOCUMENT_IMPORTED").count
        assert FidcOperation.where(tenant_id: @tenant.id, anticipation_request_id: loan.id, operation_type: "FUNDING_REQUEST").exists?
        assert ActionIpLog.where(tenant_id: @tenant.id, action_type: "FIDC_LOAN_DOCUMENT_IMPORTED", target_id: document.id).exists?
        assert ActionIpLog.where(tenant_id: @tenant.id, action_type: "FIDC_PROFITABILITY_RECORDED", target_id: loan.id).exists?
        assert AnticipationSettlementEntry.where(tenant_id: @tenant.id, anticipation_request_id: loan.id).exists?
      end
    end

    test "ops admin sees PJ loan details with linked physician" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      loan = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        physician_party = Party.create!(
          tenant: @tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Dra. Helena Carvalho",
          display_name: "Dra. Helena Carvalho",
          document_number: valid_cpf_from_seed("loan-physician-pj")
        )
        requester_pj = Party.create!(
          tenant: @tenant,
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Helena Carvalho Servicos Medicos Ltda",
          display_name: "Helena Carvalho Servicos Medicos",
          document_number: valid_cnpj_from_seed("loan-requester-pj")
        )

        PhysicianLegalEntityMembership.create!(
          tenant: @tenant,
          physician_party: physician_party,
          legal_entity_party: requester_pj,
          membership_role: "ADMIN",
          status: "ACTIVE",
          joined_at: 30.days.ago
        )

        create_loan!(
          external_reference: "AVR-PJ-001",
          requester_party: requester_pj,
          allocated_party: requester_pj,
          physician_party: physician_party,
          status: "FUNDED"
        )
      end

      get admin_loan_path(loan)

      assert_response :success
      assert_includes response.body, "Médico via PJ"
      assert_includes response.body, "Helena Carvalho Servicos Medicos"
      assert_includes response.body, "Dra. Helena Carvalho"
    end

    test "ops admin sees paginated loan list" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        21.times do |index|
          create_loan!(
            external_reference: format("AVR-PAGE-%02d", index),
            requester_party: @supplier,
            allocated_party: @supplier,
            status: "REQUESTED",
            requested_at: Time.zone.parse("2026-03-01 09:00:00") + index.minutes
          )
        end
      end

      get admin_loans_path(page: 2)

      assert_response :success
      assert_includes response.body, "Pagina 2 de 2"
      assert_includes response.body, "AVR-PAGE-00"
      refute_includes response.body, "AVR-PAGE-20"
      assert_includes response.body, "data-controller=\"clickable-row\""
    end

    test "ops admin filters loan list by PF and PJ" do
      sign_in_as(@ops_user, admin_webauthn_verified: true)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        physician_party = Party.create!(
          tenant: @tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Dr. Bruno Azevedo",
          display_name: "Dr. Bruno Azevedo",
          document_number: valid_cpf_from_seed("loan-filter-physician")
        )
        requester_pj = Party.create!(
          tenant: @tenant,
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Azevedo Servicos Medicos Ltda",
          display_name: "Azevedo Servicos Medicos",
          document_number: valid_cnpj_from_seed("loan-filter-pj")
        )

        PhysicianLegalEntityMembership.create!(
          tenant: @tenant,
          physician_party: physician_party,
          legal_entity_party: requester_pj,
          membership_role: "ADMIN",
          status: "ACTIVE",
          joined_at: 45.days.ago
        )

        create_loan!(
          external_reference: "AVR-FILTER-PF",
          requester_party: physician_party,
          allocated_party: physician_party,
          status: "REQUESTED",
          requested_at: Time.zone.parse("2026-03-05 10:00:00")
        )
        create_loan!(
          external_reference: "AVR-FILTER-PJ",
          requester_party: requester_pj,
          allocated_party: requester_pj,
          physician_party: physician_party,
          status: "REQUESTED",
          requested_at: Time.zone.parse("2026-03-05 10:05:00")
        )
      end

      get admin_loans_path(loan_structure: "pj")

      assert_response :success
      assert_includes response.body, "AVR-FILTER-PJ"
      refute_includes response.body, "AVR-FILTER-PF"
      assert_includes response.body, "Médico via PJ"

      get admin_loans_path(loan_structure: "pf")

      assert_response :success
      assert_includes response.body, "AVR-FILTER-PF"
      refute_includes response.body, "AVR-FILTER-PJ"
      assert_includes response.body, "Médico PF"
    end

    private

    def uploaded_pdf(filename:, content:)
      tempfile = Tempfile.new([ File.basename(filename, ".pdf"), ".pdf" ])
      tempfile.binmode
      tempfile.write(content)
      tempfile.rewind
      (@uploaded_tempfiles ||= []) << tempfile

      Rack::Test::UploadedFile.new(tempfile.path, "application/pdf", original_filename: filename)
    end

    def create_loan!(external_reference:, requester_party:, allocated_party:, physician_party: nil, status: "REQUESTED", requested_at: Time.zone.parse("2026-03-01 09:00:00"))
      receivable = Receivable.create!(
        tenant: @tenant,
        receivable_kind: @receivable_kind,
        debtor_party: @hospital,
        creditor_party: allocated_party,
        beneficiary_party: allocated_party,
        external_reference: external_reference,
        gross_amount: "1500.00",
        currency: "BRL",
        status: status == "SETTLED" ? "SETTLED" : (status == "FUNDED" ? "FUNDED" : "ANTICIPATION_REQUESTED"),
        performed_at: requested_at - 2.hours,
        due_at: requested_at + 45.days,
        cutoff_at: BusinessCalendar.cutoff_at(requested_at.to_date)
      )
      allocation = ReceivableAllocation.create!(
        tenant: @tenant,
        receivable: receivable,
        sequence: 1,
        allocated_party: allocated_party,
        physician_party: physician_party,
        gross_amount: "1500.00",
        tax_reserve_amount: "0.00",
        status: status == "SETTLED" ? "SETTLED" : "OPEN"
      )

      AnticipationRequest.create!(
        tenant: @tenant,
        receivable: receivable,
        receivable_allocation: allocation,
        requester_party: requester_party,
        idempotency_key: SecureRandom.uuid,
        requested_amount: "1350.00",
        discount_rate: "0.04500000",
        discount_amount: "60.75",
        net_amount: "1289.25",
        status: status,
        channel: "PORTAL",
        requested_at: requested_at,
        funded_at: status.in?(%w[FUNDED SETTLED]) ? requested_at + 8.hours : nil,
        settled_at: status == "SETTLED" ? requested_at + 2.days : nil,
        settlement_target_date: requested_at.to_date + 1
      )
    end
  end
end
