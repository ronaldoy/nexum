module AdminPasskeyMode
  extend ActiveSupport::Concern

  private

  def require_admin_passkey_step_up!(alert:)
    return if admin_passkey_satisfied?

    redirect_to new_admin_passkey_verification_path(return_to: request.fullpath), alert: alert
  end

  def admin_passkey_satisfied?
    return true if Current.session&.admin_webauthn_verified_recently?
    return false unless demo_admin_passkey_bypass_enabled?

    Current.session&.mark_admin_webauthn_verified!
    true
  end

  def demo_admin_passkey_bypass_enabled?
    ActiveModel::Type::Boolean.new.cast(
      ENV["SKIP_ADMIN_PASSKEY"].presence ||
      ENV["SHOW_SEED_CREDENTIALS"].presence ||
      ENV["SHOW_DEMO_CREDENTIALS"].presence
    )
  end
end
