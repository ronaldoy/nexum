require "integrations/escrow/account_provision_result"
require "integrations/escrow/payout_result"
require "integrations/escrow/providers/base"

module Integrations
  module Escrow
    module Providers
      class QiTech < Base
        PROVIDER_CODE = "QITECH".freeze
        ACCOUNT_REQUEST_PATH = "/v1/account_request".freeze
        PIX_TRANSFER_PATH_TEMPLATE = "/v1/account/%{source_account_key}/pix_transfer".freeze

        ACTIVE_ACCOUNT_STATUSES = %w[APPROVED ACTIVE OPEN OPENED].freeze
        REJECTED_ACCOUNT_STATUSES = %w[REJECTED DENIED CANCELED CANCELLED].freeze

        def initialize(client: nil)
          @client = client
        end

        def provider_code
          PROVIDER_CODE
        end

        def account_from_party_metadata(party:)
          raw = normalized_hash(
            party.metadata&.dig("integrations", "qitech", "escrow_account") ||
            party.metadata&.dig("qitech_escrow_account")
          )
          return nil if raw.blank?

          account_info = normalized_hash(raw["account_info"])
          account_info = {
            "branch_number" => raw["branch_number"],
            "account_number" => raw["account_number"],
            "account_digit" => raw["account_digit"],
            "account_type" => raw["account_type"] || "payment_account",
            "name" => raw["name"],
            "taxpayer_id" => raw["taxpayer_id"]
          }.compact if account_info.blank?

          provider_account_id = raw["account_key"].presence || raw["provider_account_id"].presence
          return nil if provider_account_id.blank?

          {
            provider_account_id: provider_account_id,
            provider_request_id: raw["account_request_key"].presence || raw["provider_request_id"].presence,
            status: "ACTIVE",
            metadata: {
              "source" => "party_metadata",
              "account_info" => account_info,
              "raw" => raw
            }
          }
        end

        def open_escrow_account!(tenant_id:, party:, idempotency_key:, metadata:)
          payload = account_request_payload_for(party:, idempotency_key:, metadata:)
          response = client.post(path: ACCOUNT_REQUEST_PATH, body: payload)

          account_info = normalized_hash(response["account_info"])
          provider_account_id = response["account_key"].presence || account_info["account_key"].presence
          provider_request_id = response["account_request_key"].presence

          AccountProvisionResult.new(
            provider_account_id: provider_account_id,
            provider_request_id: provider_request_id,
            status: map_account_status(response["status"]),
            metadata: {
              "request_payload" => payload,
              "response" => response,
              "account_info" => account_info
            }
          )
        end

        def create_payout!(tenant_id:, escrow_account:, recipient_party:, amount:, currency:, idempotency_key:, metadata:)
          raise ValidationError.new(code: "unsupported_currency", message: "Only BRL is supported for escrow payouts.") unless currency.to_s.upcase == "BRL"

          source_account_key = configured_source_account_key
          target_account = target_account_from(escrow_account:, recipient_party:)

          path = PIX_TRANSFER_PATH_TEMPLATE % { source_account_key: source_account_key }
          response = client.post(
            path: path,
            body: {
              "request_control_key" => metadata["provider_request_control_key"].presence || idempotency_key,
              "pix_transfer_type" => "manual",
              "target_account" => target_account,
              "transaction_amount" => amount.to_d.to_s("F"),
              "pix_message" => payout_message(metadata)
            }
          )

          PayoutResult.new(
            provider_transfer_id: response["end_to_end_id"].presence || response["transaction_id"].presence || response["id"].presence,
            status: map_payout_status(response["status"]),
            metadata: {
              "response" => response,
              "target_account" => target_account
            }
          )
        end

        private

        def client
          @client ||= begin
            signer = JwtSigner.new(
              api_client_key: configured_api_client_key,
              private_key_pem: configured_private_key,
              key_id: configured_key_id
            )
            Client.new(
              base_url: configured_base_url,
              api_client_key: configured_api_client_key,
              signer: signer,
              open_timeout: configured_open_timeout,
              read_timeout: configured_read_timeout
            )
          end
        end

        def account_request_payload_for(party:, idempotency_key:, metadata:)
          provided_payload = normalized_hash(
            metadata["qitech_account_request_payload"] ||
            party.metadata&.dig("integrations", "qitech", "account_request_payload")
          )

          if provided_payload.blank?
            raise ValidationError.new(
              code: "qitech_account_request_payload_missing",
              message: "Missing QI Tech account request payload for escrow account creation.",
              details: {
                hint: "Provide integrations.qitech.account_request_payload in party metadata."
              }
            )
          end

          provided_payload["person_type"] = person_type_for_party(party) if provided_payload["person_type"].blank?
          provided_payload["account_type"] = "ESCROW"
          provided_payload["external_reference"] ||= idempotency_key
          provided_payload
        end

        def person_type_for_party(party)
          party.kind == "PHYSICIAN_PF" ? "NATURAL_PERSON" : "LEGAL_PERSON"
        end

        def target_account_from(escrow_account:, recipient_party:)
          account_info = normalized_hash(escrow_account.metadata&.dig("account_info"))
          raw = normalized_hash(escrow_account.metadata&.dig("raw"))
          account_info = normalized_hash(raw["account_info"]) if account_info.blank?

          branch_number = account_info["branch_number"].presence || account_info["branch"].presence
          account_number = account_info["account_number"].presence || account_info["number"].presence
          account_digit = account_info["account_digit"].presence || account_info["digit"].presence
          account_type = account_info["account_type"].presence || "payment_account"

          taxpayer_id = account_info["taxpayer_id"].presence || recipient_party.document_number.to_s
          name = account_info["name"].presence || recipient_party.legal_name.to_s

          if branch_number.blank? || account_number.blank? || account_digit.blank?
            raise ValidationError.new(
              code: "qitech_target_account_incomplete",
              message: "Escrow account is missing QI Tech target account fields.",
              details: {
                escrow_account_id: escrow_account.id,
                required_fields: %w[branch_number account_number account_digit]
              }
            )
          end

          {
            "branch_number" => branch_number,
            "account_number" => account_number,
            "account_digit" => account_digit,
            "account_type" => account_type,
            "name" => name,
            "taxpayer_id" => taxpayer_id
          }
        end

        def payout_message(metadata)
          anticipation_request_id = metadata["anticipation_request_id"].to_s
          return "Antecipacao #{anticipation_request_id}" if anticipation_request_id.present?

          "Pagamento de antecipacao"
        end

        def map_account_status(raw_status)
          status = raw_status.to_s.upcase
          return "ACTIVE" if ACTIVE_ACCOUNT_STATUSES.include?(status)
          return "REJECTED" if REJECTED_ACCOUNT_STATUSES.include?(status)
          return "PENDING" if status.present?

          "PENDING"
        end

        def map_payout_status(raw_status)
          status = raw_status.to_s.upcase
          return "FAILED" if status.in?(%w[FAILED ERROR REJECTED])
          return "SENT" if status.in?(%w[SENT SUCCESS SUCCESSFUL CREATED PROCESSING PROCESSING_PAYMENT])

          "SENT"
        end

        def configured_base_url
          Rails.app.creds.option(
            :integrations,
            :qitech,
            :base_url,
            default: ENV["QITECH_BASE_URL"]
          ).presence || "https://api.qitech.com.br"
        end

        def configured_api_client_key
          value = Rails.app.creds.option(
            :integrations,
            :qitech,
            :api_client_key,
            default: ENV["QITECH_API_CLIENT_KEY"]
          )

          if value.blank?
            raise ConfigurationError.new(
              code: "qitech_api_client_key_missing",
              message: "QI Tech API client key is missing."
            )
          end

          value
        end

        def configured_private_key
          value = Rails.app.creds.option(
            :integrations,
            :qitech,
            :private_key,
            default: ENV["QITECH_PRIVATE_KEY"]
          )

          if value.blank?
            raise ConfigurationError.new(
              code: "qitech_private_key_missing",
              message: "QI Tech private key is missing."
            )
          end

          value
        end

        def configured_key_id
          Rails.app.creds.option(
            :integrations,
            :qitech,
            :key_id,
            default: ENV["QITECH_KEY_ID"]
          )
        end

        def configured_source_account_key
          value = Rails.app.creds.option(
            :integrations,
            :qitech,
            :source_account_key,
            default: ENV["QITECH_SOURCE_ACCOUNT_KEY"]
          ).to_s.strip

          if value.blank?
            raise ConfigurationError.new(
              code: "qitech_source_account_key_missing",
              message: "QI Tech source account key is missing for PIX transfers."
            )
          end

          value
        end

        def configured_open_timeout
          Rails.app.creds.option(
            :integrations,
            :qitech,
            :open_timeout_seconds,
            default: ENV["QITECH_OPEN_TIMEOUT_SECONDS"]
          ).presence || 10
        end

        def configured_read_timeout
          Rails.app.creds.option(
            :integrations,
            :qitech,
            :read_timeout_seconds,
            default: ENV["QITECH_READ_TIMEOUT_SECONDS"]
          ).presence || 30
        end

        def normalized_hash(raw)
          case raw
          when ActionController::Parameters
            normalized_hash(raw.to_unsafe_h)
          when Hash
            raw.each_with_object({}) do |(key, value), output|
              output[key.to_s] = normalize_value(value)
            end
          else
            {}
          end
        end

        def normalize_value(value)
          case value
          when ActionController::Parameters
            normalized_hash(value.to_unsafe_h)
          when Hash
            normalized_hash(value)
          when Array
            value.map { |entry| normalize_value(entry) }
          else
            value
          end
        end
      end
    end
  end
end
