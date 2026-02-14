class AddMfaToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :mfa_enabled, :boolean, null: false, default: false
    add_column :users, :mfa_secret, :string
  end
end
