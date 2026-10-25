# frozen_string_literal: true

require "time"

module CloseYourIt
  module OpenDashboard
    # Builds the response body. Service identity comes from the same ENV as GET /version, so the
    # dashboard and the deploy smoke test always agree on which build is live.
    class Report
      UNKNOWN = "unknown"

      def initialize(settings, now: Time.now.utc)
        @settings = settings
        @now = now
      end

      def to_h
        {
          open_dashboard: SPEC_VERSION,
          service: service,
          locale: @settings.locale,
          generated_at: @now.getutc.iso8601,
          metrics: @settings.metrics.map { |metric| metric.to_h(@now) }
        }
      end

      private

      def service
        {
          name: @settings.name,
          app: @settings.app,
          version: present(ENV["APP_GIT_TAG"]) || UNKNOWN,
          sha: present(ENV["APP_GIT_SHA"])&.slice(0, 7) || UNKNOWN,
          environment: CloseYourIt.configuration.environment.to_s,
          url: present(@settings.url)
        }.compact
      end

      def present(value)
        value.to_s.strip.empty? ? nil : value.to_s
      end
    end
  end
end
