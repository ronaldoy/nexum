# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw,
  :password,
  :email,
  :email_address,
  :phone,
  :document_number,
  :document_type,
  :cpf,
  :cnpj,
  :rg,
  :cnh,
  :passport,
  :crm_number,
  :legal_name,
  :full_name,
  :secret,
  :token,
  :_key,
  :crypt,
  :salt,
  :certificate,
  :otp,
  :ssn,
  :cvv,
  :cvc
]
