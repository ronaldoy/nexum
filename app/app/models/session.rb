class Session < ApplicationRecord
  belongs_to :user

  delegate :tenant, to: :user
end
