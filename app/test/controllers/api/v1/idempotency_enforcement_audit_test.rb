require "test_helper"

module Api
  module V1
    class IdempotencyEnforcementAuditTest < ActiveSupport::TestCase
      test "all mutating api v1 routes include idempotency enforcement callback" do
        missing = []

        mutating_api_v1_routes.each do |route|
          controller_path = route.defaults[:controller].to_s
          action_name = route.defaults[:action].to_s
          controller_class = "#{controller_path.camelize}Controller".safe_constantize

          if controller_class.blank?
            missing << "#{route_verb(route)} #{route.path.spec} -> missing controller class"
            next
          end

          callback_filters = controller_class._process_action_callbacks
            .select { |callback| callback.kind == :before }
            .map(&:filter)

          next if callback_filters.include?(:require_idempotency_key!)

          missing << "#{route_verb(route)} #{route.path.spec} -> #{controller_class.name}##{action_name}"
        end

        assert missing.empty?, "Missing Idempotency-Key enforcement:\n#{missing.join("\n")}"
      end

      private

      def mutating_api_v1_routes
        Rails.application.routes.routes.select do |route|
          controller = route.defaults[:controller].to_s
          path = route.path.spec.to_s
          next false unless controller.start_with?("api/v1/")
          next false unless path.start_with?("/api/v1/")

          route_verb(route).match?(/\b(POST|PATCH|PUT|DELETE)\b/)
        end
      end

      def route_verb(route)
        route.verb.to_s
      end
    end
  end
end
