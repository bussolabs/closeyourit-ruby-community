# frozen_string_literal: true

require_relative "../events/performance_issue_event"

module CloseYourIt
  module Performance
    # Turns a RequestProfile (+ request duration/route) into 0..N PerformanceIssueEvent verdicts.
    # Thresholds live in the Configuration. Detection on the client; dedup/alerts on the backend.
    class Rollup
      def self.call(...) = new(...).call

      def initialize(profile:, configuration:, route: nil, request_duration_ms: nil, trace_id: nil)
        @profile = profile
        @config = configuration
        @route = route
        @request_duration_ms = request_duration_ms
        @trace_id = trace_id
      end

      def call
        events = []
        events.concat(n_plus_one_events)
        events << high_query_count_event if high_query_count?
        events << slow_request_event if slow_request?
        events.concat(slow_external_events)
        events.compact
      end

      private

      # One verdict for every [fingerprint, call-site] group that ran more than n_plus_one_threshold times.
      def n_plus_one_events
        @profile.query_groups.values.filter_map do |group|
          next unless group[:count] > @config.n_plus_one_threshold

          build(subtype: "n_plus_one", duration_ms: group[:duration_ms], sql: group[:sql],
                source: group[:source], query_count: group[:count], count_in_request: group[:count])
        end
      end

      def high_query_count?
        (@config.query_count_threshold && @profile.query_count > @config.query_count_threshold) ||
          (@config.query_time_threshold_ms && @profile.total_query_time_ms > @config.query_time_threshold_ms)
      end

      def high_query_count_event
        build(subtype: "high_query_count", duration_ms: @profile.total_query_time_ms,
              query_count: @profile.query_count, total_query_time_ms: @profile.total_query_time_ms,
              route: @route)
      end

      def slow_request?
        @request_duration_ms && @config.slow_request_threshold_ms &&
          @request_duration_ms > @config.slow_request_threshold_ms
      end

      def slow_request_event
        build(subtype: "slow_request", duration_ms: @request_duration_ms, route: @route,
              query_count: @profile.query_count, total_query_time_ms: @profile.total_query_time_ms)
      end

      def slow_external_events
        @profile.external_calls.filter_map do |call|
          next unless call[:duration_ms] > @config.slow_external_threshold_ms

          build(subtype: "slow_external_http", duration_ms: call[:duration_ms],
                http_host: call[:host], http_url: call[:path])
        end
      end

      def build(attrs)
        PerformanceIssueEvent.new(attrs.merge(trace_id: @trace_id), @config)
      end
    end
  end
end
