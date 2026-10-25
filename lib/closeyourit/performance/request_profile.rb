# frozen_string_literal: true

module CloseYourIt
  module Performance
    # Per-request accumulator (lives in the Scope, reset at the end of the request). Counts queries,
    # groups them by [obfuscated SQL fingerprint, call site] (the prosopite pattern for N+1) and keeps
    # the external HTTP calls. Pure in-memory state: Performance::Rollup computes the verdict.
    class RequestProfile
      # Memory guard: cap on the distinct groups/calls tracked (the total count stays exact).
      MAX_GROUPS = 1000
      MAX_EXTERNAL = 500

      attr_reader :query_count, :total_query_time_ms, :query_groups, :external_calls

      def initialize
        @query_count = 0
        @total_query_time_ms = 0.0
        @query_groups = {}
        @external_calls = []
      end

      # A non-system query. Cached queries are not DB round-trips → they do not count for N+1.
      def add_query(fingerprint:, source:, duration_ms:, cached: false)
        return if cached

        ms = duration_ms.to_f
        @query_count += 1
        @total_query_time_ms += ms

        key = "#{fingerprint}\n#{source}"
        group = @query_groups[key]
        if group
          group[:count] += 1
          group[:duration_ms] += ms
        elsif @query_groups.size < MAX_GROUPS
          @query_groups[key] = { count: 1, duration_ms: ms, sql: fingerprint, source: source }
        end
      end

      def add_external(host:, path:, duration_ms:)
        return if @external_calls.size >= MAX_EXTERNAL

        @external_calls << { host: host, path: path, duration_ms: duration_ms.to_f }
      end

      def empty?
        @query_count.zero? && @external_calls.empty?
      end
    end
  end
end
