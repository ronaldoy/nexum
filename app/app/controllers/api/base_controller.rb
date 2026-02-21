module Api
  class BaseController < ActionController::API
    include ApiTokenAuthentication
    include IdempotencyEnforcement
    include RequestContext

    API_TOKEN_ROLE = "api_token".freeze
    PRIVILEGED_ROLES = %w[hospital_admin ops_admin].freeze

    class AuthorizationError < StandardError
      attr_reader :code

      def initialize(code: "forbidden", message: "Access denied.")
        @code = code
        super(message)
      end
    end
    class ScopeDeclarationError < StandardError; end

    class_attribute :api_scope_requirements, instance_writer: false, default: {}

    before_action :require_declared_api_scopes!

    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from AuthorizationError, with: :render_forbidden
    rescue_from RequestContext::ContextError, with: :render_request_context_error

    private

    class << self
      def require_api_scopes(mapping)
        normalized = mapping.to_h.each_with_object({}) do |(action_name, scopes), output|
          output[action_name.to_s] = Array(scopes).map(&:to_s)
        end

        self.api_scope_requirements = api_scope_requirements.merge(normalized)
      end
    end

    def resolved_tenant_id
      Current.api_access_token&.tenant_id || Current.user&.tenant_id
    end

    def resolved_actor_id
      actor_identifier_candidates.find(&:present?)
    end

    def resolved_role
      Current.user&.role || token_actor_role || API_TOKEN_ROLE
    end

    def render_not_found
      render_api_error(code: "not_found", message: "Resource not found.", status: :not_found)
    end

    def render_forbidden(error)
      render_api_error(code: error.code, message: error.message, status: :forbidden)
    end

    def render_request_context_error
      render_api_error(
        code: "request_context_unavailable",
        message: "Request context could not be established.",
        status: :service_unavailable
      )
    end

    def render_api_error(code:, message:, status:)
      render json: {
        error: {
          code: code,
          message: message,
          request_id: request.request_id
        }
      }, status: status
    end

    def require_api_scope!(scope)
      ensure_api_scope!(scope.to_s)
    end

    def require_declared_api_scopes!
      scopes = self.class.api_scope_requirements[action_name]
      if scopes.blank?
        raise ScopeDeclarationError, "#{self.class.name}##{action_name} must declare required API scopes."
      end

      scopes.each { |scope| ensure_api_scope!(scope) }
    end

    def ensure_api_scope!(scope)
      token_scopes = Array(Current.api_access_token&.scopes)
      return if token_scopes.include?(scope)

      raise AuthorizationError.new(code: "insufficient_scope", message: "Access denied.")
    end

    def privileged_actor?
      PRIVILEGED_ROLES.include?(Current.role.to_s)
    end

    def current_actor_party_id
      Current.user&.party_id || token_actor_party_id
    end

    def actor_identifier_candidates
      [
        Current.user&.party_id,
        Current.user&.uuid_id,
        Current.user&.id,
        token_actor_party_id,
        Current.api_access_token&.id
      ]
    end

    def token_actor_role
      metadata = Current.api_access_token&.metadata
      return nil unless metadata.is_a?(Hash)

      metadata["actor_role"].presence || metadata[:actor_role].presence
    end

    def token_actor_party_id
      metadata = Current.api_access_token&.metadata
      return nil unless metadata.is_a?(Hash)

      metadata["actor_party_id"].presence || metadata[:actor_party_id].presence
    end

    def authorize_party_access!(party_id)
      return if privileged_actor?

      actor_party_id = current_actor_party_id
      if actor_party_id.blank? || party_id.to_s != actor_party_id.to_s
        raise AuthorizationError.new(code: "forbidden", message: "Access denied.")
      end
    end

    def enforce_actor_party_binding!(party_id)
      return if privileged_actor?

      actor_party_id = current_actor_party_id
      if actor_party_id.blank? || party_id.to_s != actor_party_id.to_s
        raise AuthorizationError.new(code: "forbidden", message: "Access denied.")
      end
    end
  end
end
