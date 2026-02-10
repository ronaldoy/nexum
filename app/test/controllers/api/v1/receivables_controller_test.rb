require "test_helper"

module Api
  module V1
    class ReceivablesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @tenant = tenants(:default)
        @secondary_tenant = tenants(:secondary)
        @user = users(:one)

        @read_token = nil
        @settle_token = nil
        @receivable = nil
        @secondary_receivable = nil

        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          _, @read_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Read API",
            scopes: %w[receivables:read receivables:history]
          )
          _, @settle_token = ApiAccessToken.issue!(
            tenant: @tenant,
            user: @user,
            name: "Receivables Settle API",
            scopes: %w[receivables:settle]
          )
          @receivable = create_supplier_receivable_bundle_for_tenant!(@tenant, suffix: "tenant-a")[:receivable]
          ReceivableEvent.create!(
            tenant: @tenant,
            receivable: @receivable,
            sequence: 1,
            event_type: "RECEIVABLE_IMPORTED",
            actor_party: @receivable.creditor_party,
            actor_role: "supplier_user",
            occurred_at: Time.current,
            event_hash: SecureRandom.hex(32)
          )
        end

        with_tenant_db_context(tenant_id: @secondary_tenant.id, actor_id: @user.id, role: @user.role) do
          @secondary_receivable = create_supplier_receivable_bundle_for_tenant!(@secondary_tenant, suffix: "tenant-b")[:receivable]
        end
      end

      test "requires bearer token" do
        get api_v1_receivables_path, as: :json

        assert_response :unauthorized
        assert_equal "invalid_token", response.parsed_body.dig("error", "code")
      end

      test "lists receivables scoped by tenant context" do
        get api_v1_receivables_path, headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal 1, response.parsed_body.dig("meta", "count")
        assert_equal @receivable.id, response.parsed_body.dig("data", 0, "id")
        assert_equal "123.45", response.parsed_body.dig("data", 0, "gross_amount")
      end

      test "returns append-only history timeline" do
        get history_api_v1_receivable_path(@receivable), headers: authorization_headers(@read_token), as: :json

        assert_response :success
        assert_equal @receivable.id, response.parsed_body.dig("data", "receivable", "id")
        assert_equal "RECEIVABLE_IMPORTED", response.parsed_body.dig("data", "events", 0, "event_type")
      end

      test "settles shared cnpj receivable payment and returns cnpj, fdic and physician split" do
        bundle = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          bundle = create_shared_cnpj_physician_bundle_for_tenant!(@tenant, suffix: "settlement-cnpj")
          create_direct_anticipation_request!(
            tenant: @tenant,
            receivable: bundle[:receivable],
            allocation: bundle[:allocation],
            requester_party: bundle[:physician_one],
            idempotency_key: "idem-settlement-cnpj-anticipation",
            requested_amount: "60.00",
            discount_rate: "0.10000000",
            discount_amount: "6.00",
            net_amount: "54.00",
            status: "APPROVED"
          )
        end

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-001"),
          params: {
            settlement: {
              receivable_allocation_id: bundle[:allocation].id,
              paid_amount: "100.00",
              paid_at: Time.current.iso8601,
              metadata: { source: "hospital_erp" }
            }
          },
          as: :json

        assert_response :created
        body = response.parsed_body
        assert_equal false, body.dig("data", "replayed")
        assert_equal "30.0", body.dig("data", "cnpj_amount")
        assert_equal "66.0", body.dig("data", "fdic_amount")
        assert_equal "4.0", body.dig("data", "physician_amount")
        assert_equal 1, body.dig("data", "settlement_entries").size
      end

      test "replays settlement with same idempotency key and payload" do
        bundle = nil
        with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
          bundle = create_shared_cnpj_physician_bundle_for_tenant!(@tenant, suffix: "settlement-replay")
        end

        payload = {
          settlement: {
            receivable_allocation_id: bundle[:allocation].id,
            paid_amount: "100.00",
            paid_at: Time.current.iso8601
          }
        }

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-replay-001"),
          params: payload,
          as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")

        post settle_payment_api_v1_receivable_path(bundle[:receivable].id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-api-replay-001"),
          params: payload,
          as: :json

        assert_response :ok
        assert_equal true, response.parsed_body.dig("data", "replayed")
        assert_equal first_id, response.parsed_body.dig("data", "id")
      end

      test "requires settle scope for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@read_token, idempotency_key: "idem-settle-scope-001"),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :forbidden
        assert_equal "insufficient_scope", response.parsed_body.dig("error", "code")
      end

      test "requires idempotency key header for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@receivable.id),
          headers: authorization_headers(@settle_token),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :unprocessable_entity
        assert_equal "missing_idempotency_key", response.parsed_body.dig("error", "code")
      end

      test "enforces tenant isolation for settlement endpoint" do
        post settle_payment_api_v1_receivable_path(@secondary_receivable.id),
          headers: authorization_headers(@settle_token, idempotency_key: "idem-settle-tenant-001"),
          params: { settlement: { paid_amount: "100.00" } },
          as: :json

        assert_response :not_found
        assert_equal "not_found", response.parsed_body.dig("error", "code")
      end

      private

      def authorization_headers(raw_token, idempotency_key: nil)
        headers = { "Authorization" => "Bearer #{raw_token}" }
        headers["Idempotency-Key"] = idempotency_key if idempotency_key
        headers
      end

      def create_supplier_receivable_bundle_for_tenant!(tenant, suffix:)
        debtor = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital")
        )
        creditor = Party.create!(
          tenant: tenant,
          kind: "SUPPLIER",
          legal_name: "Fornecedor #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-supplier-creditor")
        )
        beneficiary = Party.create!(
          tenant: tenant,
          kind: "SUPPLIER",
          legal_name: "Beneficiario #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-supplier-beneficiary")
        )
        kind = ReceivableKind.create!(
          tenant: tenant,
          code: "supplier_invoice_#{suffix}",
          name: "Supplier Invoice #{suffix}",
          source_family: "SUPPLIER"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: debtor,
          creditor_party: creditor,
          beneficiary_party: beneficiary,
          external_reference: "external-#{suffix}",
          gross_amount: "123.45",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 3.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: beneficiary,
          gross_amount: receivable.gross_amount,
          tax_reserve_amount: "0.00",
          status: "OPEN"
        )

        {
          debtor: debtor,
          creditor: creditor,
          beneficiary: beneficiary,
          receivable: receivable,
          allocation: allocation
        }
      end

      def create_shared_cnpj_physician_bundle_for_tenant!(tenant, suffix:)
        hospital = Party.create!(
          tenant: tenant,
          kind: "HOSPITAL",
          legal_name: "Hospital #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-hospital")
        )
        legal_entity = Party.create!(
          tenant: tenant,
          kind: "LEGAL_ENTITY_PJ",
          legal_name: "Clinica #{suffix}",
          document_number: valid_cnpj_from_seed("#{suffix}-legal-entity")
        )
        physician_one = Party.create!(
          tenant: tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico Um #{suffix}",
          document_number: valid_cpf_from_seed("#{suffix}-physician-1")
        )
        physician_two = Party.create!(
          tenant: tenant,
          kind: "PHYSICIAN_PF",
          legal_name: "Medico Dois #{suffix}",
          document_number: valid_cpf_from_seed("#{suffix}-physician-2")
        )

        PhysicianLegalEntityMembership.create!(
          tenant: tenant,
          physician_party: physician_one,
          legal_entity_party: legal_entity,
          membership_role: "ADMIN",
          status: "ACTIVE"
        )
        PhysicianLegalEntityMembership.create!(
          tenant: tenant,
          physician_party: physician_two,
          legal_entity_party: legal_entity,
          membership_role: "MEMBER",
          status: "ACTIVE"
        )

        kind = ReceivableKind.create!(
          tenant: tenant,
          code: "physician_shift_#{suffix}",
          name: "Physician Shift #{suffix}",
          source_family: "PHYSICIAN"
        )

        receivable = Receivable.create!(
          tenant: tenant,
          receivable_kind: kind,
          debtor_party: hospital,
          creditor_party: legal_entity,
          beneficiary_party: legal_entity,
          external_reference: "external-#{suffix}",
          gross_amount: "100.00",
          currency: "BRL",
          performed_at: Time.current,
          due_at: 3.days.from_now,
          cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
        )

        allocation = ReceivableAllocation.create!(
          tenant: tenant,
          receivable: receivable,
          sequence: 1,
          allocated_party: legal_entity,
          physician_party: physician_one,
          gross_amount: "100.00",
          tax_reserve_amount: "0.00",
          status: "OPEN"
        )

        {
          hospital: hospital,
          legal_entity: legal_entity,
          physician_one: physician_one,
          physician_two: physician_two,
          receivable: receivable,
          allocation: allocation
        }
      end

      def create_direct_anticipation_request!(
        tenant:,
        receivable:,
        allocation:,
        requester_party:,
        idempotency_key:,
        requested_amount:,
        discount_rate:,
        discount_amount:,
        net_amount:,
        status:
      )
        AnticipationRequest.create!(
          tenant: tenant,
          receivable: receivable,
          receivable_allocation: allocation,
          requester_party: requester_party,
          idempotency_key: idempotency_key,
          requested_amount: requested_amount,
          discount_rate: discount_rate,
          discount_amount: discount_amount,
          net_amount: net_amount,
          status: status,
          channel: "API",
          requested_at: Time.current,
          settlement_target_date: BusinessCalendar.next_business_day(from: Time.current),
          metadata: {}
        )
      end
    end
  end
end
