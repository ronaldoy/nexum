class AdjustEscrowPayoutsForSettlementExcessFlow < ActiveRecord::Migration[8.2]
  SOURCE_REFERENCE_CHECK = "escrow_payouts_source_reference_check".freeze
  UNIQUE_SETTLEMENT_PARTY_INDEX = "index_escrow_payouts_on_tenant_settlement_party".freeze
  UNIQUE_ANTICIPATION_PARTY_INDEX = "index_escrow_payouts_on_tenant_anticipation_party".freeze

  def up
    remove_index :escrow_payouts, name: "index_escrow_payouts_on_tenant_anticipation_party", if_exists: true

    unless column_exists?(:escrow_payouts, :receivable_payment_settlement_id)
      add_reference :escrow_payouts, :receivable_payment_settlement, type: :uuid, foreign_key: true
    end

    change_column_null :escrow_payouts, :anticipation_request_id, true

    add_check_constraint(
      :escrow_payouts,
      "anticipation_request_id IS NOT NULL OR receivable_payment_settlement_id IS NOT NULL",
      name: SOURCE_REFERENCE_CHECK
    )

    add_index(
      :escrow_payouts,
      %i[tenant_id receivable_payment_settlement_id party_id],
      unique: true,
      where: "receivable_payment_settlement_id IS NOT NULL",
      name: UNIQUE_SETTLEMENT_PARTY_INDEX
    )
    add_index(
      :escrow_payouts,
      %i[tenant_id anticipation_request_id party_id],
      unique: true,
      where: "anticipation_request_id IS NOT NULL",
      name: UNIQUE_ANTICIPATION_PARTY_INDEX
    )
  end

  def down
    remove_index :escrow_payouts, name: UNIQUE_SETTLEMENT_PARTY_INDEX, if_exists: true
    remove_index :escrow_payouts, name: UNIQUE_ANTICIPATION_PARTY_INDEX, if_exists: true
    remove_check_constraint :escrow_payouts, name: SOURCE_REFERENCE_CHECK

    remove_reference :escrow_payouts, :receivable_payment_settlement, foreign_key: true
    change_column_null :escrow_payouts, :anticipation_request_id, false

    add_index(
      :escrow_payouts,
      %i[tenant_id anticipation_request_id party_id],
      unique: true,
      name: UNIQUE_ANTICIPATION_PARTY_INDEX
    )
  end
end
