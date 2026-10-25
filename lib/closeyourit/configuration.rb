# frozen_string_literal: true

require "uri"
require "concurrent"

module CloseYourIt
  # Holds all client options. Built by `CloseYourIt.init { |c| ... }`.
  # Without `endpoint_url`/`token`/`project_id` (or with `http://` in production) the client is a no-op.
  class Configuration
    DEFAULT_EXCLUDED_EXCEPTIONS = %w[
      ActionController::RoutingError
      ActiveRecord::RecordNotFound
    ].freeze

    # HTTP headers captured in the request context (never Authorization/Cookie → no PII/secrets).
    DEFAULT_REQUEST_HEADER_ALLOWLIST = %w[Accept Content-Type User-Agent Referer].freeze

    # Solid stack service tables: they are framework infrastructure, not application code. A slow
    # query on them cannot be fixed by reading your own repo — it only says the database is under
    # contention, which the app's queries already show. Excluded by DEFAULT from slowdown measurement
    # because otherwise they flood it: on closeyourit-rails on 2026-07-30 they were about 2,740
    # samples out of 4,400 (62%), all between 250 and 655 ms (CYRB-18).
    DEFAULT_EXCLUDED_QUERY_PATTERNS = [
      /\bsolid_queue_/,
      /\bsolid_cache_/,
      /\bsolid_cable_/
    ].freeze

    attr_accessor :endpoint_url, :token, :project_id, :environment, :before_send, :on_diagnostic,
                  :async_threads, :background_worker_max_queue, :shutdown_timeout,
                  :slow_query_threshold_ms, :slow_method_threshold_ms,
                  :send_pii, :obfuscate_sql, :send_server_name,
                  :capture_query_bindings, :capture_method_arguments,
                  :capture_request, :request_header_allowlist, :context_lines,
                  :capture_request_body,
                  :breadcrumbs_enabled, :max_breadcrumbs, :sample_rate,
                  :capture_handled_errors, :report_active_job_errors,
                  :logs_enabled, :logs_sample_rate, :logs_batch_size, :logs_flush_interval,
                  :capture_rails_logs, :logs_min_level, :capture_rails_logs_min_level,
                  :detect_performance_issues, :n_plus_one_threshold, :query_count_threshold,
                  :query_time_threshold_ms, :slow_request_threshold_ms, :slow_external_threshold_ms,
                  :capture_external_http, :trap_signals,
                  :monitor_jobs, :slow_job_threshold_ms, :job_queue_latency_threshold_ms,
                  :jobs_sample_rate, :job_lifecycle_logs, :propagate_trace_context,
                  :usage_enabled, :usage_flush_interval, :usage_max_symbols
    attr_writer :release, :project_root
    attr_reader :excluded_exceptions, :excluded_log_patterns, :excluded_query_patterns,
                :filter_parameters, :scrub_message_patterns, :trace_propagation_allowlist

    def initialize
      @endpoint_url = ENV.fetch("CLOSEYOURIT_ENDPOINT_URL", nil)
      @token        = ENV.fetch("CLOSEYOURIT_TOKEN", nil)
      @project_id   = ENV.fetch("CLOSEYOURIT_PROJECT_ID", nil)
      @release      = ENV.fetch("CLOSEYOURIT_RELEASE", nil)
      @environment  = ENV.fetch("CLOSEYOURIT_ENVIRONMENT") { detect_environment }

      @excluded_exceptions = DEFAULT_EXCLUDED_EXCEPTIONS.dup
      @before_send         = nil

      # Opt-in diagnostic hook: `->(event, details) { ... }` called at every stage of an event's
      # lifecycle (:enqueue, :send, :drop, :timeout, :shutdown) with details free of sensitive data
      # (e.g. `{ reason: :queue_full }`, `{ status: 429 }`). Local and non-recursive: it sends no
      # telemetry and cannot trigger self-monitoring loops (see CloseYourIt.notify_diagnostic, CYRB-12).
      @on_diagnostic = nil

      @async_threads               = default_threads
      @background_worker_max_queue  = 30
      # How long to wait, on process exit, for in-flight sends to complete. Default: the duration cap
      # of ONE POST, so the last batch is not abandoned halfway (CYRB-24).
      # Lower it if process exit must be faster than delivery.
      @shutdown_timeout = Transport::MAX_REQUEST_SECONDS

      # Intercepts SIGTERM to guarantee the end-of-life flush (deploy/Kamal): by default SIGTERM ends
      # the process WITHOUT running at_exit. OPT-IN because it overrides any TERM handler of the host
      # app. See CloseYourIt.shutdown / register_shutdown_flush (CYRB-5).
      @trap_signals = false

      @slow_query_threshold_ms  = 100
      @slow_method_threshold_ms = 200
      # Queries NOT to measure as slowdowns (match on the SQL text). Default: the Solid stack service
      # tables. Whoever really wants to measure them clears the list.
      @excluded_query_patterns = DEFAULT_EXCLUDED_QUERY_PATTERNS.dup

      @send_pii         = false
      @obfuscate_sql    = true
      @send_server_name = true

      # HTTP request context (method/url/header allowlist). Body/query/IP only with send_pii.
      @capture_request          = true
      @request_header_allowlist = DEFAULT_REQUEST_HEADER_ALLOWLIST.dup

      # Source lines around each stacktrace frame (pre/context/post). 0 = disabled.
      @context_lines = 3

      # Request body params in the event (`request.data`), extracted LAZILY only when the error
      # happens, sanitized and scrubbed (denylist + filter_parameters). The backend scrubs again
      # defensively. Uploads → placeholder, 64 KB cap. Gated by send_pii: with it OFF the body
      # is never sent, whatever this flag says (CYRB-28).
      @capture_request_body = true

      # Breadcrumbs: history (obfuscated queries, custom events) attached to the error.
      @breadcrumbs_enabled = true
      @max_breadcrumbs     = 100

      # Probabilistic sampling of errors/messages (1.0 = send everything, 0.0 = nothing).
      @sample_rate = 1.0

      # Captures handled errors (Rails.error.report) and ActiveJob/Sidekiq errors (otherwise lost).
      @capture_handled_errors   = true
      @report_active_job_errors = true

      # Captures parameter values — opt-in, default OFF (privacy). Binds/arguments may contain PII.
      @capture_query_bindings   = false
      @capture_method_arguments = false

      # Structured logs (CloseYourIt.log / .logger). Dedicated master switch + sampling + batching.
      @logs_enabled        = true
      @logs_sample_rate    = 1.0
      @logs_batch_size     = 50
      @logs_flush_interval = 5

      # CYSK-29 — usage telemetry: which routes/jobs/keys actually run. The payload carries no user
      # data by construction (route = Controller#action, never the URL), so the default is ON:
      # thirty days of optional collection taught us that optional means never.
      # The registry is emptied on every flush: the cap limits DISTINCT symbols per window.
      @usage_enabled        = true
      @usage_flush_interval = 300
      @usage_max_symbols    = 2000
      # Opt-in Rails.logger broadcast → CloseYourIt.log (default OFF; sends only ≥ threshold).
      @capture_rails_logs = false
      @logs_min_level     = :info
      # DEDICATED threshold of the Rails.logger broadcast, separate from logs_min_level (which governs
      # CloseYourIt.log/.logger, where the dev chooses what to log). Default :warn — conservative:
      # without it, in high-traffic production EVERY framework info line (Started GET, Rendered, ...)
      # would flood the stream with tens of thousands of log entries/min (CYRB-7). Whoever also wants
      # the framework info lines lowers it explicitly (e.g. :info).
      @capture_rails_logs_min_level = :warn
      # Rails.logger broadcast noise that is NOT an exception, so excluded_exceptions cannot cover it:
      # repeated framework or gem lines. Regexp on the message text, empty by default. Applies ONLY
      # to the automatic broadcast, never to an explicit CloseYourIt.log.
      @excluded_log_patterns = []

      # Performance issue detection (aggregate verdicts: N+1, slow request, slow external HTTP).
      # OPT-IN, default OFF: it profiles EVERY query of the request → non-negligible overhead, enable it
      # deliberately per app. Thresholds are conservative (little noise). See Performance::Rollup.
      @detect_performance_issues = false
      @n_plus_one_threshold      = 10        # same fingerprint+call-site run > N times in one request
      @query_count_threshold     = 100       # too many total queries in one request
      @query_time_threshold_ms   = 500       # total DB time per request beyond which = high_query_count
      @slow_request_threshold_ms = 1000      # total request duration
      @slow_external_threshold_ms = 1000     # single external HTTP call
      @capture_external_http     = true      # instruments Net::HTTP (only with detect_performance_issues)

      # Background job metrics: execution duration and queue wait (queue latency) for ActiveJob and
      # Sidekiq. ON by default (unlike detect_performance_issues): visibility of slow/late/retried jobs
      # must not require manual instrumentation in every app (CYRB-14), and the overhead is low — one
      # notification per job, not profiling of every query. Noise is kept down by the thresholds
      # (normal jobs under threshold = no metric) and by sampling. The label is the job class name;
      # arguments are NEVER sent.
      @monitor_jobs                   = true
      @job_lifecycle_logs             = false
      @slow_job_threshold_ms          = 5000     # perform duration beyond which = slow_job
      @job_queue_latency_threshold_ms = 60_000   # enqueue→execution wait beyond which = job_queue_latency
      @jobs_sample_rate               = 1.0      # fraction of over-threshold candidates actually sent

      # W3C trace context propagation (traceparent/tracestate) to external services called via
      # Net::HTTP. OPT-IN, default OFF: injecting outgoing headers crosses a trust boundary and must be
      # decided per app. It is limited PER DESTINATION by the allowlist (exact hosts, case-insensitive,
      # or Regexp for subdomains); empty list = no destination. Never to unlisted hosts, never as
      # `baggage` (which may carry PII). Inbound, a valid traceparent becomes the trace_id of the
      # CloseYourIt events → the request's errors/metrics correlate with the distributed trace (CYRB-15).
      @propagate_trace_context     = false
      @trace_propagation_allowlist = []

      # Project root: base for the relative frame filename (cross-SDK culprit). Lazy: auto-detected
      # from Rails.root or Dir.pwd on first access when not set explicitly.
      @project_root = nil

      @filter_parameters      = []
      @scrub_message_patterns = []
    end

    # Classes/strings → name (String); Regexps stay Regexps (pattern match on name/message).
    def excluded_exceptions=(list)
      @excluded_exceptions = Array(list).map { |item| item.is_a?(Regexp) ? item : item.to_s }
    end

    # Rails.logger broadcast patterns to drop. Strings become Regexps (literal match on the text):
    # whoever writes `config.excluded_log_patterns = ["Rendered layout"]` means exactly that.
    def excluded_log_patterns=(list)
      @excluded_log_patterns = Array(list).map { |item| item.is_a?(Regexp) ? item : Regexp.new(Regexp.escape(item.to_s)) }
    end

    # Queries not to measure. Same normalization as excluded_log_patterns: String = literal text
    # (a table name is written that way, not as a pattern), Regexp = pattern.
    def excluded_query_patterns=(list)
      @excluded_query_patterns = Array(list).map { |item| item.is_a?(Regexp) ? item : Regexp.new(Regexp.escape(item.to_s)) }
    end

    def filter_parameters=(list)
      @filter_parameters = Array(list)
    end

    # Adds the host app's `Rails.application.config.filter_parameters` (strings/symbols/regexps) to the
    # gem list, without duplicates. Rails filter procs are dropped: they mutate values in place, while
    # the Scrubber matches keys only (CYRB-28).
    def merge_filter_parameters(list)
      @filter_parameters |= Array(list).reject { |item| item.respond_to?(:call) }
    end

    # Destinations allowed to receive the W3C trace headers. String = exact host (case-insensitive
    # match), Regexp = pattern (for subdomains/host families). Empty list = none.
    def trace_propagation_allowlist=(list)
      @trace_propagation_allowlist = Array(list)
    end

    def scrub_message_patterns=(list)
      @scrub_message_patterns = Array(list)
    end

    def production?
      environment.to_s == "production"
    end

    # The client sends only with complete credentials (endpoint + token + project_id) and a secure
    # transport (http:// allowed outside production).
    def enabled?
      return false if blank?(endpoint_url) || blank?(token) || blank?(project_id)
      return false if insecure_endpoint? && production?

      true
    end

    # Logs configuration warnings (e.g. http:// endpoint, malformed project_id/endpoint).
    # Never raises: consistent with the client's no-op philosophy. Called by `CloseYourIt.init`.
    def validate!
      CloseYourIt.internal_logger.warn(insecure_endpoint_message) if insecure_endpoint?
      CloseYourIt.internal_logger.warn(malformed_project_id_message) if malformed_project_id?
      CloseYourIt.internal_logger.warn(malformed_endpoint_message) if malformed_endpoint?
      self
    end

    # Effective release: the one set, otherwise auto-detected (deploy/CI ENV or git).
    def release
      return @release unless @release.nil?

      @release = detect_release
    end

    # Effective project root: the one set, otherwise auto-detected (Rails.root or Dir.pwd).
    # Used to make `frame.filename` relative (culprit comparable across SDKs — CYRB-4).
    def project_root
      return @project_root unless @project_root.nil?

      @project_root = detect_project_root
    end

    # Rails.root when the app runs under Rails, otherwise the working directory. Never raises.
    def detect_project_root
      return ::Rails.root.to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root

      Dir.pwd
    rescue StandardError
      Dir.pwd
    end

    # A semver tag (optional `v`) is preferred to the short SHA as release: it converges with what the
    # CI records (it tags), while the short SHA creates duplicate releases on the backend (CYRB-9).
    SEMVER_TAG = /\Av?\d+\.\d+\.\d+([-+.].+)?\z/

    # Release auto-detection: first a semver tag (APP_GIT_TAG/GIT_TAG), then the short SHA from the
    # deploy/CI env or from git. Never raises.
    def detect_release
      detect_tag ||
        ENV["KAMAL_VERSION"] ||
        ENV["GIT_SHA"] ||
        ENV["GIT_REVISION"] ||
        ENV["SOURCE_VERSION"] ||
        ENV["HEROKU_SLUG_COMMIT"] ||
        git_revision
    rescue StandardError
      nil
    end

    private

    # `.git` is a directory in a normal checkout and a file in a worktree → File.directory? is false
    # in worktrees, so tests do not spawn git subprocesses (deterministic).
    def git_revision
      return nil unless File.directory?(".git")

      sha = `git rev-parse --short HEAD 2>/dev/null`.strip
      sha.empty? ? nil : sha
    rescue StandardError
      nil
    end

    # Semver tag from APP_GIT_TAG then GIT_TAG: accepts only a non-blank value shaped like semver
    # (optional v + MAJOR.MINOR.PATCH + optional suffix). Rejects `unknown`, empty, branch names,
    # etc. → nil, so detect_release falls back to the SHA chain.
    def detect_tag
      tag = ENV["APP_GIT_TAG"] || ENV["GIT_TAG"]
      return nil if blank?(tag)

      SEMVER_TAG.match?(tag) ? tag : nil
    end

    UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def insecure_endpoint?
      uri = parsed_endpoint
      !uri.nil? && uri.scheme != "https"
    end

    # Warns when project_id is set but does not look like a UUID (the typical mistake is pasting a
    # slug/name instead of the id). It does not block: the server is the authority on validity.
    def malformed_project_id?
      !blank?(project_id) && !UUID_FORMAT.match?(project_id.to_s)
    end

    def malformed_project_id_message
      "CloseYourIt: project_id (#{project_id}) is not shaped like a UUID — check that you copied the right id."
    end

    # Warns when endpoint_url is set but not parsable or has no host.
    def malformed_endpoint?
      return false if blank?(endpoint_url)

      uri = parsed_endpoint
      uri.nil? || blank?(uri.host)
    end

    def malformed_endpoint_message
      "CloseYourIt: endpoint_url (#{endpoint_url}) is not a valid URL (missing host)."
    end

    def insecure_endpoint_message
      tail = production? ? "Telemetry DISABLED in production." : "Allowed only in development."
      "CloseYourIt: endpoint_url uses insecure http:// (#{endpoint_url}) — the token would travel in clear text. #{tail}"
    end

    def parsed_endpoint
      return nil if blank?(endpoint_url)

      URI.parse(endpoint_url)
    rescue URI::InvalidURIError
      nil
    end

    def detect_environment
      return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env

      ENV["RAILS_ENV"] || ENV["RACK_ENV"] || "development"
    end

    def default_threads
      [ (Concurrent.processor_count / 2.0).ceil, 1 ].max
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
