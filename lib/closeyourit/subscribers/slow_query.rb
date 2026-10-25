# frozen_string_literal: true

require_relative "../events/slow_query_event"
require_relative "../scrubber"
require_relative "../scope"

module CloseYourIt
  module Subscribers
    # Receives the data of a `sql.active_record` event and, if the query exceeds the threshold
    # (excluding SCHEMA/CACHE/TRANSACTION), sends a `slow_query` event.
    # Pure logic: the wiring to ActiveSupport::Notifications lives in the Railtie.
    class SlowQuery
      IGNORED_NAMES = %w[SCHEMA CACHE TRANSACTION].freeze

      def initialize(configuration = nil)
        @configuration = configuration
      end

      # Entry point of the Railtie's sql.active_record block. `source` is a callable: the call site costs
      # a full backtrace plus the Rails cleaner, so it is resolved at most once and only when needed.
      def notify(payload, duration_ms, source)
        resolved = false
        site = nil
        lazy_source = lambda do
          site = source.call unless resolved
          resolved = true
          site
        end
        name = payload[:name]
        sql = payload[:sql]
        cached = payload.fetch(:cached, false)
        record(name: name, duration_ms: duration_ms, sql: sql, cached: cached,
               connection: payload[:connection], binds: payload[:binds],
               type_casted_binds: payload[:type_casted_binds], source: lazy_source)
        breadcrumb(name: name, sql: sql, duration_ms: duration_ms, cached: cached)
        profile(name: name, sql: sql, duration_ms: duration_ms, cached: cached, source: lazy_source)
      end

      def record(name:, duration_ms:, sql:, cached: false, connection: nil,
                 binds: nil, type_casted_binds: nil, source: nil)
        config = @configuration || CloseYourIt.configuration
        return if ignored_name?(name)
        return if duration_ms < config.slow_query_threshold_ms
        return if excluded_sql?(config, sql)

        event = SlowQueryEvent.new(
          { name: name, sql: sql, cached: cached, connection: connection,
            binds: binds, type_casted_binds: type_casted_binds, source: resolve(source) },
          duration_ms,
          config
        )
        CloseYourIt.capture_event(event)
      rescue StandardError
        # Telemetry must never disturb the host query.
        nil
      end

      # Breadcrumb for EVERY non-system query (not only slow ones): obfuscated SQL, no binds.
      # Gives the "which queries before the crash" history attached to the error event.
      def breadcrumb(name:, sql:, duration_ms:, cached: false)
        config = @configuration || CloseYourIt.configuration
        return if ignored_name?(name)
        return unless config.breadcrumbs_enabled

        CloseYourIt.add_breadcrumb(
          category: "query",
          type: "query",
          message: scrubber(config).obfuscate_sql(sql),
          data: { "name" => name, "duration_ms" => duration_ms.to_f.round(2), "cached" => cached }
        )
      rescue StandardError
        # Telemetry must never disturb the host query.
        nil
      end

      # Pushes EVERY non-system query into the Scope's RequestProfile (for N+1 detection at the end of
      # the request). Only with detect_performance_issues: fingerprint = obfuscated SQL + call site.
      def profile(name:, sql:, duration_ms:, cached: false, source: nil)
        config = @configuration || CloseYourIt.configuration
        return unless config.detect_performance_issues
        return if ignored_name?(name)

        CloseYourIt::Scope.current.performance_profile.add_query(
          fingerprint: scrubber(config).obfuscate_sql(sql),
          source: resolve(source), duration_ms: duration_ms, cached: cached
        )
      rescue StandardError
        # Telemetry must never disturb the host query.
        nil
      end

      private

      def resolve(source) = source.respond_to?(:call) ? source.call : source

      def scrubber(config)
        @scrubber ||= Scrubber.new(config)
      end

      def ignored_name?(name)
        name.nil? || IGNORED_NAMES.include?(name)
      end

      # Query excluded from slowdown MEASUREMENT (config.excluded_query_patterns). The filter lives
      # only here, not in #breadcrumb nor in #profile:
      #
      #   - breadcrumb: the "which queries before the crash" history has diagnostic value even when the
      #     query belongs to the framework — hiding it would make the sequence incomplete and misleading;
      #   - profile: it is per-request and serves N+1 detection, where a service table read many times
      #     is itself a symptom worth seeing.
      #
      # A slowdown is worth measuring if someone can act on it; a breadcrumb is worth keeping if it
      # helps understanding. They are two different questions, and this list answers only the first.
      def excluded_sql?(config, sql)
        return false if sql.nil?

        patterns = config.excluded_query_patterns
        return false if patterns.empty?

        text = sql.to_s
        patterns.any? { |pattern| pattern.match?(text) }
      end
    end
  end
end
