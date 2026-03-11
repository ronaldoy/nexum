require "test_helper"

module Admin
  class PasskeyVerificationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @tenant = tenants(:default)
      @ops_user = users(:one)
      @non_privileged_user = users(:two)

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: "ops_admin") do
        @ops_user.update!(role: "ops_admin")
      end
    end

    test "ops_admin can open passkey verification page" do
      sign_in_as(@ops_user)

      get new_admin_passkey_verification_path

      assert_response :success
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    test "non privileged user cannot open passkey verification page" do
      sign_in_as(@non_privileged_user)

      get new_admin_passkey_verification_path

      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, "Acesso restrito ao perfil de operação."
    end

    test "registration_options issues a challenge for ops_admin" do
      sign_in_as(@ops_user)

      post registration_options_admin_passkey_verification_path, as: :json

      assert_response :success
      assert response.parsed_body["challenge"].present?
      @ops_user.reload
      assert @ops_user.webauthn_id.present?
    end

    test "registration_options uses request host as rp id" do
      host! "127.0.0.1"
      sign_in_as(@ops_user)

      post registration_options_admin_passkey_verification_path, as: :json

      assert_response :success
      assert_equal "127.0.0.1", response.parsed_body.dig("rp", "id")
    end

    test "authentication_options requires existing credential" do
      sign_in_as(@ops_user)

      post authentication_options_admin_passkey_verification_path, as: :json

      assert_response :unprocessable_entity
      assert_equal "passkey_not_registered", response.parsed_body.dig("error", "code")
    end

    test "authentication_options issues challenge when credential exists" do
      sign_in_as(@ops_user)
      create_webauthn_credential!

      post authentication_options_admin_passkey_verification_path, as: :json

      assert_response :success
      assert response.parsed_body["challenge"].present?
    end

    test "register preserves browser credential payload and creates passkey" do
      sign_in_as(@ops_user)
      session_id = Current.session.id

      post registration_options_admin_passkey_verification_path, as: :json
      assert_response :success

      received_payloads = []
      fake_credential = Struct.new(:id, :public_key, :sign_count) do
        def verify(challenge)
          raise ArgumentError, "missing challenge" if challenge.blank?

          true
        end
      end.new("credential-register", "test-public-key", 0)
      fake_relying_party = Object.new
      fake_relying_party.define_singleton_method(:verify_registration) do |payload, challenge|
        received_payloads << payload
        fake_credential.verify(challenge)
        fake_credential
      end

      with_singleton_method_stub(WebAuthn::RelyingParty, :new, ->(**) {
        fake_relying_party
      }) do
        post register_admin_passkey_verification_path, params: {
          public_key_credential: browser_registration_payload
        }, as: :json
      end

      assert_response :created
      assert_equal true, response.parsed_body.dig("data", "registered")
      assert_equal true, response.parsed_body.dig("data", "verified")

      payload = received_payloads.fetch(0)
      assert_equal browser_registration_payload["rawId"], payload["rawId"]
      assert_equal browser_registration_payload.dig("response", "attestationObject"), payload.dig("response", "attestationObject")
      assert_equal browser_registration_payload.dig("response", "clientDataJSON"), payload.dig("response", "clientDataJSON")

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: @ops_user.role) do
        credential = WebauthnCredential.find_by!(tenant: @tenant, user: @ops_user, webauthn_id: "credential-register")
        assert_equal "test-public-key", credential.public_key
        assert Session.find(session_id).admin_webauthn_verified_at.present?
      end
    end

    test "verify preserves browser assertion payload and updates credential" do
      sign_in_as(@ops_user)
      session_id = Current.session.id
      create_webauthn_credential!
      credential_id = with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: @ops_user.role) do
        @ops_user.webauthn_credentials.order(created_at: :asc).last.webauthn_id
      end

      post authentication_options_admin_passkey_verification_path, as: :json
      assert_response :success

      received_payloads = []
      fake_assertion = Struct.new(:id, :sign_count) do
        def verify(challenge, public_key:, sign_count:)
          raise ArgumentError, "missing challenge" if challenge.blank?
          raise ArgumentError, "missing public key" if public_key.blank?
          raise ArgumentError, "invalid sign count" if sign_count.nil?

          true
        end
      end.new(credential_id, 9)
      fake_relying_party = Object.new

      fake_relying_party.define_singleton_method(:verify_authentication) do |payload, challenge, &block|
        received_payloads << payload
        stored_credential = block.call(fake_assertion)
        fake_assertion.verify(
          challenge,
          public_key: stored_credential.public_key,
          sign_count: stored_credential.sign_count
        )
        [ fake_assertion, stored_credential ]
      end

      with_singleton_method_stub(WebAuthn::RelyingParty, :new, ->(**) {
        fake_relying_party
      }) do
        post verify_admin_passkey_verification_path, params: {
          public_key_credential: browser_assertion_payload(credential_id)
        }, as: :json
      end

      assert_response :success
      assert_equal true, response.parsed_body.dig("data", "verified")

      payload = received_payloads.fetch(0)
      assert_equal credential_id, payload["rawId"]
      assert_equal "assertion-authenticator-data", payload.dig("response", "authenticatorData")
      assert_equal "assertion-signature", payload.dig("response", "signature")

      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: @ops_user.role) do
        assert_equal 9, WebauthnCredential.find_by!(tenant: @tenant, user: @ops_user, webauthn_id: credential_id).sign_count
        assert Session.find(session_id).admin_webauthn_verified_at.present?
      end
    end

    test "explicit skip flag redirects away from passkey screen" do
      sign_in_as(@ops_user)

      with_environment("SKIP_ADMIN_PASSKEY" => "true") do
        get new_admin_passkey_verification_path(return_to: admin_dashboard_path)
      end

      assert_redirected_to admin_dashboard_path
    end

    test "show demo credentials flag does not bypass passkey screen" do
      sign_in_as(@ops_user)

      with_environment("SHOW_SEED_CREDENTIALS" => "true") do
        get new_admin_passkey_verification_path(return_to: admin_dashboard_path)
      end

      assert_response :success
      assert_includes response.body, "Validar acesso ao painel administrativo"
    end

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    private

    def create_webauthn_credential!
      with_tenant_db_context(tenant_id: @tenant.id, actor_id: @ops_user.id, role: @ops_user.role) do
        @ops_user.ensure_webauthn_id!
        WebauthnCredential.create!(
          tenant: @tenant,
          user: @ops_user,
          webauthn_id: "credential-#{SecureRandom.hex(8)}",
          public_key: "test-public-key",
          sign_count: 0,
          nickname: "Test key"
        )
      end
    end

    def browser_registration_payload
      {
        "id" => "credential-register",
        "type" => "public-key",
        "rawId" => "credential-register",
        "authenticatorAttachment" => "platform",
        "clientExtensionResults" => { "credProps" => { "rk" => true } },
        "response" => {
          "attestationObject" => "registration-attestation-object",
          "clientDataJSON" => "registration-client-data-json"
        }
      }
    end

    def browser_assertion_payload(credential_id)
      {
        "id" => credential_id,
        "type" => "public-key",
        "rawId" => credential_id,
        "authenticatorAttachment" => "platform",
        "clientExtensionResults" => {},
        "response" => {
          "authenticatorData" => "assertion-authenticator-data",
          "clientDataJSON" => "assertion-client-data-json",
          "signature" => "assertion-signature",
          "userHandle" => @ops_user.uuid_id
        }
      }
    end

    def with_environment(overrides)
      previous = overrides.keys.to_h { |key| [ key, ENV[key] ] }
      overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    def with_singleton_method_stub(object, method_name, implementation)
      singleton_class = class << object
        self
      end
      original_method = singleton_class.instance_method(method_name)
      singleton_class.define_method(method_name, implementation)
      yield
    ensure
      singleton_class.define_method(method_name, original_method) if original_method
    end
  end
end
