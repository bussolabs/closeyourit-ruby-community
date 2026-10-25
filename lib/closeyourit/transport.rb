# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"

module CloseYourIt
  # Sends a payload to an ingest path (errors → /events, metrics → /metrics) via HTTP POST
  # with `Authorization: Bearer`. Never raises: every network error is logged and swallowed.
  class Transport
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3
    # Net::HTTP does not follow redirects: the canonical host may answer 301 (e.g. apex → www).
    # We re-POST to Location keeping method + body, so the event is not silently lost.
    MAX_REDIRECTS = 2

    # Maximum duration of ONE send_event: open + read, repeated for every followed redirect. It is the
    # cap the end-of-life drain must be able to wait for, otherwise it abandons a still healthy send
    # (CYRB-24).
    MAX_REQUEST_SECONDS = (OPEN_TIMEOUT + READ_TIMEOUT) * (MAX_REDIRECTS + 1)

    # A network timeout (open or read) is a special send failure: we keep it apart from non-2xx and
    # other network errors because it typically signals connectivity problems (CYRB-12).
    TIMEOUT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Timeout::Error ].freeze

    def initialize(configuration)
      @configuration = configuration
    end

    def send_event(payload, path:)
      response = post(payload, path)
      if response.is_a?(Net::HTTPSuccess)
        CloseYourIt.stats.increment(:sent)
        CloseYourIt.notify_diagnostic(:send, status: response.code.to_i)
      else
        CloseYourIt.stats.increment(:failed)
        CloseYourIt.internal_logger.warn("CloseYourIt transport: HTTP #{response.code}#{error_detail(response)} on #{path}")
        CloseYourIt.notify_diagnostic(:drop, reason: :response, status: response.code.to_i)
      end
      response
    rescue StandardError => e
      CloseYourIt.stats.increment(:failed)
      CloseYourIt.internal_logger.error("CloseYourIt transport: #{e.class}: #{e.message}")
      if timeout_error?(e)
        CloseYourIt.stats.increment(:timeout)
        CloseYourIt.notify_diagnostic(:timeout, error: e.class.name)
      else
        CloseYourIt.notify_diagnostic(:drop, reason: :network, error: e.class.name)
      end
      nil
    end

    private

    def timeout_error?(error)
      TIMEOUT_ERRORS.any? { |klass| error.is_a?(klass) }
    end

    def post(payload, path)
      body = JSON.generate(payload)
      origin = URI.parse("#{base_url}#{path}")
      uri = origin
      redirects = 0

      loop do
        response = post_once(uri, body, authorize: same_authority?(origin, uri))
        location = response["location"] if response.is_a?(Net::HTTPRedirection)
        return response unless location && redirects < MAX_REDIRECTS

        redirects += 1
        uri = redirect_uri(uri, location)
      end
    end

    def post_once(uri, body, authorize:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      # The Bearer is an ingest secret: do not resend it after a redirect to a different host
      # (or an https→http downgrade), so it is never handed to an untrusted endpoint.
      request["Authorization"] = "Bearer #{@configuration.token}" if authorize
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "closeyourit-ruby/#{VERSION}"
      request.body = body

      http.request(request)
    end

    # Location may be absolute (https://www.…) or relative (/api/…): resolve it against the current URI.
    def redirect_uri(current, location)
      target = URI.parse(location)
      target.relative? ? current + target : target
    end

    # The Bearer is resent only if the redirect stays on the configured endpoint's authority:
    # same host (or its www variant), same effective port and no https→http downgrade.
    # The port is part of the trust boundary (CYRB-22): on the same server a different port is a
    # separate service, which must not receive the ingest secret.
    def same_authority?(origin, target)
      return false if origin.scheme == "https" && target.scheme != "https"
      return false unless canonical_host(origin) == canonical_host(target)

      origin.port == target.port || canonical_upgrade?(origin, target)
    end

    # An endpoint configured as `http` that redirects to `https` stays trusted: the port changes only
    # because the scheme changes (80 → 443), not because it points to a service on a non-standard port.
    def canonical_upgrade?(origin, target)
      origin.scheme == "http" && target.scheme == "https" &&
        origin.port == origin.default_port && target.port == target.default_port
    end

    # An explicit port equal to the default (`:443` on https) is the same as omitting it: `URI#port`
    # already normalizes it, only the www variant of the canonical host is left to neutralize here.
    def canonical_host(uri)
      uri.host.to_s.sub(/\Awww\./, "")
    end

    # Extracts " R…: message" from the backend error envelope, so the dev sees the error code in the
    # diagnostic log (not only the HTTP status). Silent if the body is not the expected envelope.
    def error_detail(response)
      body = JSON.parse(response.body.to_s)
      error = body["error"]
      return "" unless error.is_a?(Hash)

      detail = [ error["code"], error["message"] ].compact.join(": ")
      detail.empty? ? "" : " #{detail}"
    rescue StandardError
      ""
    end

    def base_url
      @configuration.endpoint_url.to_s.chomp("/")
    end
  end
end
