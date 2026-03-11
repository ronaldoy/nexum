class FixAuthChallengeDigestCheck < ActiveRecord::Migration[8.2]
  CONSTRAINT_NAME = "auth_challenges_code_digest_format_check".freeze
  CONSTRAINT_EXPRESSION = "code_digest ~ '^(hmac-sha256-v1\\$)?[0-9a-f]{64}$'".freeze

  def up
    remove_check_constraint :auth_challenges, name: CONSTRAINT_NAME if check_constraint_exists?(:auth_challenges, name: CONSTRAINT_NAME)

    execute <<~SQL
      ALTER TABLE auth_challenges
      ADD CONSTRAINT #{CONSTRAINT_NAME}
      CHECK (#{CONSTRAINT_EXPRESSION})
      NOT VALID
    SQL
  end

  def down
    remove_check_constraint :auth_challenges, name: CONSTRAINT_NAME if check_constraint_exists?(:auth_challenges, name: CONSTRAINT_NAME)
  end
end
