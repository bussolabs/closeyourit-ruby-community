# frozen_string_literal: true

module CloseYourIt
  # Open Dashboard standard: GET /open-dashboard returns who the service is and its business
  # numbers, behind a per-service token. Contract: contracts/open-dashboard/v1.
  module OpenDashboard
    SPEC_VERSION = "1.0"
    PATH = "/open-dashboard"
    MAX_METRICS = 50

    class << self
      # Kept separate from CloseYourIt.init: init rebuilds its configuration on every call, and the
      # dashboard declaration must not disappear when telemetry is reconfigured.
      def configure
        candidate = Settings.new
        yield candidate
        candidate.validate!
        @settings = candidate
      end

      attr_reader :settings

      def reset!
        @settings = nil
      end
    end
  end
end

require_relative "open_dashboard/metric"
require_relative "open_dashboard/settings"
require_relative "open_dashboard/report"
require_relative "open_dashboard/middleware"
