# frozen_string_literal: true

require "logger"

module CloseYourIt
  module Rails
    # Logger-compatible sink attached to Rails.logger (opt-in broadcast, `config.capture_rails_logs`):
    # every app log ≥ threshold (`capture_rails_logs_min_level`, default :warn) is forwarded to
    # CloseYourIt.log → ingest /logs. Below threshold: no-op (nothing sent). The default is
    # conservative (:warn) so the stream is not flooded with framework info noise (CYRB-7). It writes
    # to no device (it only forwards).
    class LogBroadcast < ::Logger
      SEVERITY_LEVELS = { 0 => "debug", 1 => "info", 2 => "warning", 3 => "error", 4 => "fatal", 5 => "fatal" }.freeze
      LEVEL_BY_SYMBOL = { debug: 0, info: 1, warn: 2, warning: 2, error: 3, fatal: 4 }.freeze

      def initialize(min_level = :warn)
        super(nil) # no device: it only forwards
        self.level = LEVEL_BY_SYMBOL.fetch(min_level.to_sym, 2)
      end

      # Overrides ::Logger's single entry point: filters by threshold and by exclusions, then forwards
      # to CloseYourIt.log. The second filter exists because the threshold alone cannot tell noise
      # apart: an `ActionController::RoutingError` from a missing favicon is a `logger.error` like any
      # other, and without checking the TEXT it came back through the log channel after being excluded
      # from the errors one (CYRB-17). Gating lives here and not in `CloseYourIt.log`: that method also
      # serves the dev who writes a log on purpose, and their lines are never silenced.
      def add(severity, message = nil, progname = nil)
        severity ||= ::Logger::UNKNOWN
        return true if severity < level

        text = message || (block_given? ? yield : nil) || progname
        return true if text.nil? || CloseYourIt.ignored_log_message?(text)

        CloseYourIt.log(SEVERITY_LEVELS.fetch(severity, "info"), text)
        true
      end
    end
  end
end
