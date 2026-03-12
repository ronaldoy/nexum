require "test_helper"

class ReceivingAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:default)
    @user = users(:one)
    @party = parties(:default_supplier_party)
  end

  test "creates a primary pix receiving account and logs the update" do
    sign_in_as(@user)

    assert_difference("ReceivingAccount.count", 1) do
      assert_difference("ActionIpLog.where(action_type: 'RECEIVING_ACCOUNT_UPDATED').count", 1) do
        post receiving_account_path, params: {
          receiving_account: {
            bank_code: "20018183",
            branch_code: "0001",
            account_number: "123456-7",
            account_type: "checking"
          }
        }
      end
    end

    assert_redirected_to root_path

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "supplier_user") do
      account = ReceivingAccount.find_by!(tenant_id: @tenant.id, party_id: @party.id)

      assert_equal "PIX", account.payment_rail
      assert_equal "ACTIVE", account.status
      assert_equal true, account.primary
      assert_equal "20018183", account.bank_code
      assert_equal "0001", account.branch_code
      assert_equal "123456-7", account.account_number
      assert_equal "checking", account.account_type
      assert_equal @party.legal_name, account.holder_name
      assert_equal @party.document_number, account.holder_document_number
      assert_equal "portal_dashboard", account.metadata["updated_from"]

      action_log = ActionIpLog.order(created_at: :desc).find_by!(
        tenant_id: @tenant.id,
        action_type: "RECEIVING_ACCOUNT_UPDATED",
        target_type: "ReceivingAccount",
        target_id: account.id
      )
      assert_equal "PORTAL", action_log.channel
      assert_equal @party.id, action_log.actor_party_id
      assert_equal "20018183", action_log.metadata["bank_code"]
    end
  end

  test "updates the existing primary receiving account instead of creating a second one" do
    existing_account = nil

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "supplier_user") do
      existing_account = ReceivingAccount.create!(
        tenant: @tenant,
        party: @party,
        payment_rail: "PIX",
        status: "ACTIVE",
        primary: true,
        bank_code: "11111111",
        branch_code: "0001",
        account_number: "123456-7",
        account_type: "checking",
        holder_name: @party.legal_name,
        holder_document_number: @party.document_number,
        metadata: {}
      )
    end

    sign_in_as(@user)

    assert_no_difference("ReceivingAccount.count") do
      post receiving_account_path, params: {
        receiving_account: {
          bank_code: "22222222",
          branch_code: "0002",
          account_number: "765432-1",
          account_type: "payment"
        }
      }
    end

    assert_redirected_to root_path

    with_tenant_db_context(tenant_id: @tenant.id, actor_id: @user.id, role: "supplier_user") do
      account = ReceivingAccount.find_by!(tenant_id: @tenant.id, party_id: @party.id)

      assert_equal existing_account.id, account.id
      assert_equal "22222222", account.bank_code
      assert_equal "0002", account.branch_code
      assert_equal "765432-1", account.account_number
      assert_equal "payment", account.account_type
    end
  end

  test "redirects back to the dashboard without persisting changes when the account is invalid" do
    sign_in_as(@user)

    assert_no_difference("ReceivingAccount.count") do
      assert_no_difference("ActionIpLog.where(action_type: 'RECEIVING_ACCOUNT_UPDATED').count") do
        post receiving_account_path, params: {
          receiving_account: {
            bank_code: "123",
            branch_code: "0001",
            account_number: "123456-7",
            account_type: "checking"
          }
        }
      end
    end

    assert_redirected_to root_path
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Bank code is invalid"
  end
end
