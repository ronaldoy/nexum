require "test_helper"

class AssignmentContractTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
  end

  test "normalizes currency and emits contract creation event" do
    with_default_tenant_context do
      bundle = create_receivable_bundle!(suffix: "assignment-contract-create")
      contract = AssignmentContract.create!(
        tenant: @tenant,
        receivable: bundle.fetch(:receivable),
        assignor_party: bundle.fetch(:assignor_party),
        assignee_party: bundle.fetch(:assignee_party),
        contract_number: "CT-#{SecureRandom.hex(4)}",
        idempotency_key: "idem-contract-create-#{SecureRandom.uuid}",
        status: "SIGNED",
        currency: "brl",
        assigned_amount: "1500.00",
        signed_at: Time.current
      )

      event = ReceivableEvent.where(tenant_id: @tenant.id, receivable_id: bundle.fetch(:receivable).id).order(sequence: :asc).last

      assert_equal "BRL", contract.currency
      assert_equal "ASSIGNMENT_CONTRACT_CREATED", event.event_type
      assert_equal contract.id, event.payload.fetch("assignment_contract_id")
      assert_equal "SIGNED", event.payload.fetch("status_after")
    end
  end

  test "emits status change event when contract status transitions" do
    with_default_tenant_context do
      bundle = create_receivable_bundle!(suffix: "assignment-contract-status")
      contract = AssignmentContract.create!(
        tenant: @tenant,
        receivable: bundle.fetch(:receivable),
        assignor_party: bundle.fetch(:assignor_party),
        assignee_party: bundle.fetch(:assignee_party),
        contract_number: "CT-#{SecureRandom.hex(4)}",
        idempotency_key: "idem-contract-status-#{SecureRandom.uuid}",
        status: "DRAFT",
        currency: "BRL",
        assigned_amount: "980.00"
      )

      contract.update!(status: "ACTIVE", signed_at: Time.current)

      events = ReceivableEvent.where(tenant_id: @tenant.id, receivable_id: bundle.fetch(:receivable).id).order(sequence: :asc)

      assert_equal [ "ASSIGNMENT_CONTRACT_CREATED", "ASSIGNMENT_CONTRACT_STATUS_CHANGED" ], events.pluck(:event_type)
      assert_equal "DRAFT", events.last.payload.fetch("status_before")
      assert_equal "ACTIVE", events.last.payload.fetch("status_after")
    end
  end

  private

  def with_default_tenant_context
    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: @user.role) do
      yield
    end
  end

  def create_receivable_bundle!(suffix:)
    debtor_party = Party.create!(
      tenant: @tenant,
      kind: "HOSPITAL",
      legal_name: "Hospital #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-hospital")
    )
    creditor_party = Party.create!(
      tenant: @tenant,
      kind: "SUPPLIER",
      legal_name: "Fornecedor #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-supplier")
    )
    beneficiary_party = Party.create!(
      tenant: @tenant,
      kind: "SUPPLIER",
      legal_name: "Beneficiario #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-beneficiary")
    )
    assignee_party = Party.create!(
      tenant: @tenant,
      kind: "FIDC",
      legal_name: "FIDC #{suffix}",
      document_number: valid_cnpj_from_seed("#{suffix}-fdic")
    )
    receivable_kind = ReceivableKind.create!(
      tenant: @tenant,
      code: "assignment_contract_#{suffix}_#{SecureRandom.hex(3)}",
      name: "Assignment Contract Kind #{suffix}",
      source_family: "SUPPLIER"
    )
    receivable = Receivable.create!(
      tenant: @tenant,
      receivable_kind: receivable_kind,
      debtor_party: debtor_party,
      creditor_party: creditor_party,
      beneficiary_party: beneficiary_party,
      external_reference: "assignment-contract-#{suffix}-#{SecureRandom.hex(3)}",
      gross_amount: "2000.00",
      currency: "BRL",
      performed_at: Time.current,
      due_at: 3.days.from_now,
      cutoff_at: BusinessCalendar.cutoff_at(Time.current.in_time_zone.to_date)
    )

    {
      receivable: receivable,
      assignor_party: creditor_party,
      assignee_party: assignee_party
    }
  end
end
