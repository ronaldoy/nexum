class PasswordsMailer < ApplicationMailer
  def reset(user, tenant_slug: nil)
    @user = user
    @tenant_slug = tenant_slug.presence || user.tenant&.slug
    mail subject: "Reset your password", to: user.email_address
  end
end
