# frozen_string_literal: true

require "uri"
require_relative "../scope"

module CloseYourIt
  module Rails
    # Prepended to Net::HTTP: times every external call and pushes it into the Scope's RequestProfile,
    # so the request window can detect slow external HTTP. Transparent (returns the original response)
    # and defensive (no-op when telemetry is off; never raises because of profiling). Excludes calls to
    # the CloseYourIt endpoint itself (no loop).
    module NetHTTPPatch
      def request(req, body = nil, &block)
        config = CloseYourIt.configuration
        # W3C propagation: independent of profiling (it has its own opt-in), must happen BEFORE the
        # round-trip because it adds headers to the outgoing request.
        inject_trace_context(config, req)
        return super unless config.detect_performance_issues && config.capture_external_http

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          super
        ensure
          duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
          record_external(config, req, duration_ms)
        end
      end

      private

      # Handles the W3C trace headers on the outgoing request (only with opt-in propagation ON).
      # To an allowed destination it injects traceparent/tracestate; to any other it REMOVES them.
      # Removal is the defense against leaks on cross-host redirects: if the same request object is
      # reused to follow a redirect to a host not in the allowlist, the previous call's headers must not
      # survive ("external hosts do not receive internal headers" — CYRB-15).
      # baggage is never read nor emitted. Defensive: never raises because of propagation.
      def inject_trace_context(config, req)
        return unless config.propagate_trace_context

        context = deliverable_context(config)
        if context.nil?
          strip_trace_headers(req)
        else
          context.headers.each { |name, value| req[name] = value }
        end
      rescue StandardError
        nil
      end

      # The trace context to deliver to THIS destination, or nil if nothing must be propagated: missing
      # host, the CloseYourIt endpoint itself (no self-propagation), destination outside the allowlist,
      # or a scope without context.
      def deliverable_context(config)
        host = address
        return nil if host.nil? || own_endpoint?(config, host)
        return nil unless destination_allowed?(config, host)

        CloseYourIt::Scope.current.trace_context
      end

      # Is the destination allowed to receive the trace context? String = exact host (case-insensitive),
      # Regexp = pattern (subdomains/families). Empty list → always false (no destination).
      def destination_allowed?(config, host)
        config.trace_propagation_allowlist.any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(host) : pattern.to_s.casecmp?(host)
        end
      end

      # Removes the W3C trace headers a previous call on the same request object may have left.
      # Only our headers, nothing else; no-op if the request does not support them.
      def strip_trace_headers(req)
        return unless req.respond_to?(:delete)

        req.delete("traceparent")
        req.delete("tracestate")
      end

      def record_external(config, req, duration_ms)
        host = address
        return if host.nil? || own_endpoint?(config, host)

        CloseYourIt::Scope.current.performance_profile.add_external(
          host: host, path: templatize_path(req), duration_ms: duration_ms
        )
      rescue StandardError
        # Profiling must never disturb the host call.
        nil
      end

      def own_endpoint?(config, host)
        endpoint = config.endpoint_url
        return false if endpoint.nil?

        URI.parse(endpoint).host == host
      rescue URI::InvalidURIError
        false
      end

      # Path without query string, with uuids and runs of ≥3 digits → placeholders (same route = same
      # signature). The ≥3 digit threshold keeps API versions like "/v1" and templatizes real ids
      # ("/v1/charges/ch_12345" → "/v1/charges/ch_<n>", "/users/123" → "/users/<n>").
      def templatize_path(req)
        path = req.respond_to?(:path) ? req.path.to_s : ""
        path.split("?", 2).first.to_s
            .gsub(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "<uuid>")
            .gsub(/\d{3,}/, "<n>")
      end
    end
  end
end
