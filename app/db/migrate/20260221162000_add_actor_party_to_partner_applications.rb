class AddActorPartyToPartnerApplications < ActiveRecord::Migration[8.2]
  def change
    add_reference :partner_applications,
      :actor_party,
      type: :uuid,
      foreign_key: { to_table: :parties },
      index: true
  end
end
