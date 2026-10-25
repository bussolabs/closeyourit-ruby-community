# frozen_string_literal: true

require "securerandom"
require_relative "../trace_context"

module CloseYourIt
  module Rails
    # Rack middleware: populates the Scope with the request's HTTP context (method/url/headers)
    # so the error event captured downstream knows "on which page" it happened. It must wrap
    # `CaptureExceptions` (insert_before) to be already populated when the exception bubbles up.
    # Pure Rack (reads `env`, no Rails dependency) → testable in isolation.
    class RequestContext
      # Headers without the HTTP_ prefix in the Rack env.
      RAW_HEADERS = %w[CONTENT_TYPE CONTENT_LENGTH].freeze

      # Correlation cookie written by the browser SDK (session replay): opaque id of the
      # replay session, carried by every same-origin request.
      REPLAY_COOKIE = "cyi_replay"

      def initialize(app)
        @app = app
      end

      def call(env)
        if enabled?
          # W3C trace context (only with opt-in propagation): adopted from the incoming header or generated.
          context = trace_context_for(env)
          CloseYourIt::Scope.current.trace_context = context
          # trace_id always (log↔error correlation), even with capture_request OFF. With a W3C trace
          # context the events' trace_id IS the W3C trace-id → the error/metric lines up with the
          # distributed trace propagated downstream (trace_id mapping, CYRB-15); otherwise request_id as before.
          CloseYourIt::Scope.current.trace_id = context ? context.trace_id : trace_id_for(env)
          # Server error ↔ session replay correlation: the id from the cookie lands on the scope
          # → the event's contexts.replay.replay_id (same spot as the JS path).
          CloseYourIt::Scope.current.replay_session_id = replay_session_id_for(env)
          if CloseYourIt.configuration.capture_request
            CloseYourIt::Scope.current.request = build_request(env)
            # Reference to the env for LAZY body extraction (request.data) once the event is built.
            CloseYourIt::Scope.current.rack_env = env
          end
        end
        @app.call(env)
      ensure
        CloseYourIt::Scope.reset!
      end

      private

      def enabled?
        CloseYourIt.enabled?
      rescue StandardError
        false
      end

      # W3C trace context of the request, ONLY with opt-in propagation on (otherwise nil → historical
      # behavior unchanged). Adopts a valid incoming traceparent/tracestate (distributed correlation),
      # otherwise generates a root: so services that ORIGINATE traffic also start with a W3C trace-id
      # that can be propagated downstream. A malformed traceparent is ignored → a root is generated.
      def trace_context_for(env)
        return nil unless CloseYourIt.configuration.propagate_trace_context

        CloseYourIt::TraceContext.parse(env["HTTP_TRACEPARENT"], env["HTTP_TRACESTATE"]) ||
          CloseYourIt::TraceContext.generate
      end

      # Reuses the Rails/Rack request id when present (same correlation as the application logs),
      # otherwise generates one.
      def trace_id_for(env)
        env["action_dispatch.request_id"] ||
          env["HTTP_X_REQUEST_ID"].to_s.split(",").first&.strip.then { |id| id&.empty? ? nil : id } ||
          SecureRandom.uuid
      end

      # Extracts `cyi_replay` from the request cookie (nil if absent). Pure Rack.
      def replay_session_id_for(env)
        cookie = env["HTTP_COOKIE"]
        return nil if cookie.nil? || cookie.empty?

        # `rack/utils` loaded lazily: the middleware runs only inside a Rack app (where Rack is surely
        # present), so `require "closeyourit-ruby"` does not force Rack on non-web apps (CLI/workers)
        # and the gem stays installable without declaring `rack` as a dependency (CYRB-13).
        require "rack/utils"
        Rack::Utils.parse_cookies_header(cookie)[REPLAY_COOKIE].to_s.then { |id| id.empty? ? nil : id }
      end

      # Sentry `request` shape. URL without query string; headers only from the allowlist (never
      # Authorization/Cookie). query_string + IP only with send_pii (opt-in).
      def build_request(env)
        request = {
          "method"  => env["REQUEST_METHOD"],
          "url"     => build_url(env),
          "headers" => allowed_headers(env)
        }.reject { |_key, value| value.nil? }

        if CloseYourIt.configuration.send_pii
          query = env["QUERY_STRING"]
          request["query_string"] = query if query && !query.empty?
          ip = env["REMOTE_ADDR"]
          request["env"] = { "REMOTE_ADDR" => ip } if ip
        end

        request
      rescue StandardError
        # Telemetry must never disturb the host request.
        nil
      end

      def build_url(env)
        scheme = env["rack.url_scheme"] || "http"
        host = env["HTTP_HOST"] || env["SERVER_NAME"]
        return nil if host.nil?

        "#{scheme}://#{host}#{env["PATH_INFO"]}"
      end

      def allowed_headers(env)
        CloseYourIt.configuration.request_header_allowlist.each_with_object({}) do |name, acc|
          value = env[header_env_key(name)]
          acc[name] = value if value
        end
      end

      def header_env_key(name)
        upcased = name.upcase.tr("-", "_")
        RAW_HEADERS.include?(upcased) ? upcased : "HTTP_#{upcased}"
      end
    end
  end
end
