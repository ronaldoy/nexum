class AddMfaLastOtpAtToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :mfa_last_otp_at, :datetime
  end
end
