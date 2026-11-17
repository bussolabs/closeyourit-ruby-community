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

      # Body of the Railtie's process_action.action_controller listener: route usage (CYSK-29) + the
      # performance verdicts. It runs on the request's thread, and ActiveSupport::Notifications
      # re-raises a subscriber's error into the request: a fault here (usage registry, rollup) would
      # break a response that already succeeded. Absorbed and logged, like the other listeners (CYRB-35).
      def process_action(payload, duration_ms)
        # The route is `Controller#action`, NEVER the URL. The usage_enabled gate lives inside #record.
        route = "#{payload[:controller]}##{payload[:action]}"
        CloseYourIt.usage_registry.record("route", route) if CloseYourIt.enabled?
        record(route: route, duration_ms: duration_ms)
      rescue StandardError => e
        CloseYourIt.internal_log(:warn, "CloseYourIt request observation failed: #{e.class}: #{e.message}")
        nil
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
