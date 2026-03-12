class ReceivingAccountsController < ApplicationController
  def create
    account = upsert_receiving_account!
    redirect_to root_path, notice: "Conta recebedora PIX atualizada para #{account.party.legal_name}."
  rescue ActiveRecord::RecordInvalid => error
    redirect_to root_path, alert: error.record.errors.full_messages.to_sentence
  end

  private

  def upsert_receiving_account!
    party = Current.user&.party
    if party.blank?
      invalid_record = ReceivingAccount.new
      invalid_record.errors.add(:base, "Usuário atual não possui entidade vinculada para receber pagamentos.")
      raise ActiveRecord::RecordInvalid.new(invalid_record)
    end

    account = ReceivingAccount.find_or_initialize_by(
      tenant_id: Current.user.tenant_id,
      party_id: party.id,
      primary: true
    )
    account.assign_attributes(
      payment_rail: "PIX",
      status: "ACTIVE",
      bank_code: receiving_account_params.fetch(:bank_code),
      branch_code: receiving_account_params.fetch(:branch_code),
      account_number: receiving_account_params.fetch(:account_number),
      account_type: receiving_account_params.fetch(:account_type),
      holder_name: party.legal_name,
      holder_document_number: party.document_number,
      metadata: (account.metadata || {}).merge(
        "updated_from" => "portal_dashboard",
        "updated_at" => Time.current.utc.iso8601(6)
      )
    )
    account.save!

    log_receiving_account_update!(account)
    account
  end

  def log_receiving_account_update!(account)
    ActionIpLog.create!(
      tenant_id: account.tenant_id,
      actor_party_id: Current.user&.party_id,
      action_type: "RECEIVING_ACCOUNT_UPDATED",
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      request_id: request.request_id,
      endpoint_path: request.fullpath,
      http_method: request.method,
      channel: "PORTAL",
      target_type: "ReceivingAccount",
      target_id: account.id,
      success: true,
      occurred_at: Time.current,
      metadata: {
        "payment_rail" => account.payment_rail,
        "bank_code" => account.bank_code,
        "account_type" => account.account_type
      }
    )
  end

  def receiving_account_params
    params.require(:receiving_account).permit(:bank_code, :branch_code, :account_number, :account_type)
  end
end
