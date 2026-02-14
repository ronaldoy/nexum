class AddForeignKeysToAnticipationRequestEvents < ActiveRecord::Migration[8.2]
  def up
    unless foreign_key_exists?(:anticipation_request_events, :tenants)
      add_foreign_key :anticipation_request_events, :tenants
    end

    unless foreign_key_exists?(:anticipation_request_events, :anticipation_requests)
      add_foreign_key :anticipation_request_events, :anticipation_requests
    end

    unless foreign_key_exists?(:anticipation_request_events, :parties, column: :actor_party_id)
      add_foreign_key :anticipation_request_events, :parties, column: :actor_party_id
    end

    unless index_exists?(:anticipation_request_events, :actor_party_id)
      add_index :anticipation_request_events, :actor_party_id
    end
  end

  def down
    remove_index :anticipation_request_events, :actor_party_id if index_exists?(:anticipation_request_events, :actor_party_id)

    if foreign_key_exists?(:anticipation_request_events, :parties, column: :actor_party_id)
      remove_foreign_key :anticipation_request_events, column: :actor_party_id
    end

    remove_foreign_key :anticipation_request_events, :anticipation_requests if foreign_key_exists?(:anticipation_request_events, :anticipation_requests)
    remove_foreign_key :anticipation_request_events, :tenants if foreign_key_exists?(:anticipation_request_events, :tenants)
  end
end
