class CreateApiAccessTokens < ActiveRecord::Migration[8.2]
  def change
    create_table :api_access_tokens, id: :uuid do |t|
      t.references :tenant, null: false, type: :uuid, foreign_key: true
      t.references :user, foreign_key: true
      t.string :name, null: false
      t.string :token_identifier, null: false
      t.string :token_digest, null: false
      t.string :scopes, array: true, default: [], null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_check_constraint :api_access_tokens, "char_length(token_identifier) > 0", name: "api_access_tokens_token_identifier_check"
    add_check_constraint :api_access_tokens, "char_length(token_digest) > 0", name: "api_access_tokens_token_digest_check"
    add_index :api_access_tokens, :token_identifier, unique: true
    add_index :api_access_tokens, %i[tenant_id revoked_at expires_at], name: "index_api_access_tokens_on_tenant_lifecycle"

    execute <<~SQL
      ALTER TABLE api_access_tokens ENABLE ROW LEVEL SECURITY;
      ALTER TABLE api_access_tokens FORCE ROW LEVEL SECURITY;
      DROP POLICY IF EXISTS api_access_tokens_tenant_policy ON api_access_tokens;
      CREATE POLICY api_access_tokens_tenant_policy
      ON api_access_tokens
      USING (tenant_id = app_current_tenant_id())
      WITH CHECK (tenant_id = app_current_tenant_id());
    SQL
  end
end
