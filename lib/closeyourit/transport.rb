# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "timeout"
require "concurrent"

module CloseYourIt
  # Sends a payload to an ingest path (errors → /events, metrics → /metrics) via HTTP POST
  # with `Authorization: Bearer`. Never raises: every network error is logged and swallowed.
  class Transport
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3
    # Net::HTTP does not follow redirects: the canonical host may answer 301 (e.g. apex → www).
    # We re-POST to Location keeping method + body, so the event is not silently lost — but only while
    # Location stays on the configured endpoint's authority (see #same_authority?).
    MAX_REDIRECTS = 2

    # Maximum duration of ONE send_event: open + read, repeated for every followed redirect. It is the
    # cap the end-of-life drain must be able to wait for, otherwise it abandons a still healthy send
    # (CYRB-24). Retries do not stretch it: on process exit the pending wait is interrupted and no new
    # attempt starts (see #stop_retries!).
    MAX_REQUEST_SECONDS = (OPEN_TIMEOUT + READ_TIMEOUT) * (MAX_REDIRECTS + 1)

    # A busy server or a passing failure is retried, like the Python client (CYRB-44): at most
    # MAX_RETRIES more attempts, waiting RETRY_BASE_DELAY doubled at every attempt plus up to 100%
    # jitter, or the server's Retry-After. No wait ever exceeds MAX_RETRY_DELAY: Python allows 30s,
    # but here a few threads serve a queue of 30, and a long wait would fill it and drop other events.
    MAX_RETRIES = 2
    RETRY_BASE_DELAY = 1.0
    MAX_RETRY_DELAY = 5.0
    # Statuses meaning "not now" rather than "never": retried together with every 5xx. Any other
    # non-2xx (400 bad data, 401 bad token, 404 unknown project, a refused redirect…) is final.
    RETRY_STATUSES = [ 408, 425, 429 ].freeze

    # A network timeout (open or read) is a special send failure: we keep it apart from non-2xx and
    # other network errors because it typically signals connectivity problems (CYRB-12).
    TIMEOUT_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Timeout::Error ].freeze

    # `retries` is the number of extra attempts after the first one. The Client passes 0 when the
    # worker is synchronous (async_threads 0): there the send runs on the app's thread, and waiting
    # would slow the app down.
    def initialize(configuration, retries: 0, random: Random.new)
      @configuration = configuration
      @retries = retries.to_i
      @random = random
      @stopping = Concurrent::Event.new
    end

    def send_event(payload, path:)
      body = JSON.generate(payload)
      uri = URI.parse("#{base_url}#{path}")
      attempt = 0

      loop do
        response, error = attempt_post(uri, body, path)
        return succeeded(response) if response.is_a?(Net::HTTPSuccess)
        return failed(response, error, path) unless retry?(response, error, attempt)

        attempt += 1
        delay = retry_delay(response, attempt)
        CloseYourIt.notify_diagnostic(:retry, attempt: attempt, delay: delay, **failure_details(response, error))
        # Process exit during the wait: it ends at once and no new attempt starts.
        return failed(response, error, path) if pause(delay)

        # Counted only once the wait is over and the attempt really starts: an interrupted one is not.
        CloseYourIt.stats.increment(:retried)
      end
    rescue StandardError => e
      failed(nil, e, path)
    end

    # Called on process exit (Client#shutdown) BEFORE the worker drain: a pending wait is interrupted
    # and no new attempt starts, so the drain still lasts at most MAX_REQUEST_SECONDS per send.
    def stop_retries!
      @stopping.set
    end

    private

    def timeout_error?(error)
      TIMEOUT_ERRORS.any? { |klass| error.is_a?(klass) }
    end

    # One attempt, redirects included. A network error is returned rather than raised, so the retry
    # loop decides on it like on a status.
    def attempt_post(uri, body, path)
      [ post(uri, body, path), nil ]
    rescue StandardError => e
      [ nil, e ]
    end

    def succeeded(response)
      CloseYourIt.stats.increment(:sent)
      CloseYourIt.notify_diagnostic(:send, status: response.code.to_i)
      response
    end

    # The send is lost: counted as failed ONCE, however many attempts it took.
    def failed(response, error, path)
      CloseYourIt.stats.increment(:failed)
      if response
        CloseYourIt.internal_logger.warn("CloseYourIt transport: HTTP #{response.code}#{error_detail(response)} on #{path}")
        CloseYourIt.notify_diagnostic(:drop, reason: :response, status: response.code.to_i)
        return response
      end

      CloseYourIt.internal_logger.error("CloseYourIt transport: #{error.class}: #{error.message}")
      if timeout_error?(error)
        CloseYourIt.stats.increment(:timeout)
        CloseYourIt.notify_diagnostic(:timeout, error: error.class.name)
      else
        CloseYourIt.notify_diagnostic(:drop, reason: :network, error: error.class.name)
      end
      nil
    end

    # Network errors and timeouts are always transient; a response only with a "not now" status.
    def retry?(response, error, attempt)
      return false if attempt >= @retries || @stopping.set?
      return true if error

      status = response.code.to_i
      RETRY_STATUSES.include?(status) || status >= 500
    end

    # Why the attempt failed, free of sensitive data: the same vocabulary as the :drop diagnostic.
    def failure_details(response, error)
      return { reason: :response, status: response.code.to_i } if response

      { reason: timeout_error?(error) ? :timeout : :network, error: error.class.name }
    end

    # The server's Retry-After wins; otherwise RETRY_BASE_DELAY doubled per attempt plus jitter.
    # Either way capped at MAX_RETRY_DELAY.
    def retry_delay(response, attempt)
      requested = retry_after(response)
      return [ requested, MAX_RETRY_DELAY ].min if requested

      base = RETRY_BASE_DELAY * (2**(attempt - 1))
      [ base + (base * @random.rand), MAX_RETRY_DELAY ].min
    end

    # Retry-After in seconds ("1") or as an HTTP date. nil when absent or unreadable.
    def retry_after(response)
      value = response && response["retry-after"]
      return nil if value.nil?

      seconds = Float(value.strip, exception: false) || (Time.httpdate(value.strip) - Time.now)
      [ seconds, 0.0 ].max
    rescue ArgumentError
      nil
    end

    # Waits `seconds`, unless the process is exiting. Returns true when the wait was interrupted.
    def pause(seconds)
      @stopping.wait(seconds)
    end

    def post(uri, body, path)
      origin = uri
      redirects = 0

      loop do
        response = post_once(uri, body)
        location = response["location"] if response.is_a?(Net::HTTPRedirection)
        return response unless location && redirects < MAX_REDIRECTS

        target = redirect_uri(uri, location)
        # The payload is as sensitive as the Bearer (stack traces, tags, request data): a redirect off
        # the configured endpoint's authority is not followed at all (CYRB-31). The redirect response
        # is returned, so send_event counts it as failed like any other non-2xx.
        return refuse_redirect(response, target, path) unless same_authority?(origin, target)

        redirects += 1
        uri = target
      end
    end

    def refuse_redirect(response, target, path)
      CloseYourIt.internal_logger.warn(
        "CloseYourIt transport: redirect to #{target.scheme}://#{target.host}:#{target.port} on #{path} " \
        "refused: it leaves the configured endpoint (other host, other port or https→http). " \
        "Set endpoint_url to the final address."
      )
      response
    end

    def post_once(uri, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      # Only reached on the configured endpoint's authority (see #post): the Bearer always goes.
      request["Authorization"] = "Bearer #{@configuration.token}"
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

    # A redirect is followed (body + Bearer) only if it stays on the configured endpoint's authority:
    # same host (or its www variant), same effective port and no https→http downgrade.
    # The port is part of the trust boundary (CYRB-22): on the same server a different port is a
    # separate service, which must receive neither the ingest secret nor the payload (CYRB-31).
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
