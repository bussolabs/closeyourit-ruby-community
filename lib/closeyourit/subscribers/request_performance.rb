# frozen_string_literal: true

require_relative "../scope"
require_relative "../performance/rollup"

module CloseYourIt
  module Subscribers
    # At the end of the request (process_action.action_controller) turns the RequestProfile collected
    # in the Scope into performance_issue verdicts and sends them (fire-and-forget). The Scope — and so
    # the profile — is reset right after by RequestContext#call (ensure). Pure logic: the wiring to
    # ActiveSupport::Notifications lives in the Railtie.
    class RequestPerformance
      def initialize(configuration = nil)
        @configuration = configuration
      end

      def record(route:, duration_ms:)
        config = @configuration || CloseYourIt.configuration
        return unless config.detect_performance_issues

        profile = CloseYourIt::Scope.current.performance_profile
        return if profile.empty? && !slow_request?(config, duration_ms)

        events = CloseYourIt::Performance::Rollup.call(
          profile: profile, configuration: config, route: route,
          request_duration_ms: duration_ms, trace_id: CloseYourIt::Scope.current.trace_id
        )
        events.each { |event| CloseYourIt.capture_event(event) }
      end

      private

      def slow_request?(config, duration_ms)
        duration_ms && config.slow_request_threshold_ms && duration_ms > config.slow_request_threshold_ms
      end
    end
  end
end
