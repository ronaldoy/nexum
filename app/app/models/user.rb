class User < ApplicationRecord
  ROLES = Role::CODES
  PRIVILEGED_ROLES = %w[hospital_admin ops_admin].freeze
  MFA_ALLOWED_DRIFT_STEPS = 1

  belongs_to :tenant
  belongs_to :party, optional: true

  encrypts :email_address, deterministic: true
  encrypts :mfa_secret

  has_secure_password algorithm: :argon2
  has_many :sessions, dependent: :destroy
  has_many :api_access_tokens, dependent: :destroy
  has_many :user_roles, dependent: :restrict_with_exception
  has_many :roles, through: :user_roles

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  before_validation :normalize_pending_role_code
  after_save :sync_primary_role_assignment!, if: :pending_role_code?

  validates :email_address, presence: true, uniqueness: true
  validates :mfa_secret, presence: true, if: :mfa_enabled?
  validate :role_presence
  validate :role_inclusion

  def role
    @pending_role_code.presence || roles.pick(:code)
  end

  def role=(value)
    @pending_role_code = value
  end

  def mfa_required_for_role?
    PRIVILEGED_ROLES.include?(role.to_s)
  end

  def valid_mfa_code?(otp_code)
    return false unless mfa_enabled?
    return false if mfa_secret.to_s.strip.blank?
    return false if otp_code.to_s.strip.blank?

    timestamp = ROTP::TOTP.new(mfa_secret).verify(
      otp_code.to_s.strip,
      drift_behind: MFA_ALLOWED_DRIFT_STEPS,
      drift_ahead: MFA_ALLOWED_DRIFT_STEPS,
      after: mfa_last_otp_at&.to_i
    )
    return false if timestamp.blank?

    update_columns(
      mfa_last_otp_at: Time.at(timestamp).utc,
      updated_at: Time.current
    )

    true
  end

  private

  def pending_role_code?
    @pending_role_code.present?
  end

  def normalize_pending_role_code
    normalized = @pending_role_code.to_s.strip.downcase
    @pending_role_code = normalized.presence
  end

  def role_presence
    return if role.present?

    errors.add(:role, :blank)
  end

  def role_inclusion
    return if role.blank?
    return if ROLES.include?(role)

    errors.add(:role, :inclusion)
  end

  def sync_primary_role_assignment!
    return if tenant.blank?

    role_record = tenant.roles.find_or_create_by!(code: @pending_role_code) do |record|
      record.name = @pending_role_code.humanize
    end
    existing_user_role = user_roles.order(:assigned_at, :created_at).first

    if existing_user_role.present?
      if existing_user_role.role_id != role_record.id || existing_user_role.tenant_id != tenant_id
        existing_user_role.update!(tenant: tenant, role: role_record, assigned_at: Time.current)
      end
    else
      user_roles.create!(tenant: tenant, role: role_record, assigned_at: Time.current)
    end
  ensure
    @pending_role_code = nil
  end
end
