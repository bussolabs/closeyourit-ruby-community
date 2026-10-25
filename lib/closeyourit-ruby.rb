# frozen_string_literal: true

require "logger"

require_relative "closeyourit/version"
require_relative "closeyourit/configuration"
require_relative "closeyourit/breadcrumb"
require_relative "closeyourit/trace_context"
require_relative "closeyourit/scope"
require_relative "closeyourit/scrubber"
require_relative "closeyourit/stats"
require_relative "closeyourit/background_worker"
require_relative "closeyourit/transport"
require_relative "closeyourit/event"
require_relative "closeyourit/events/error_event"
require_relative "closeyourit/events/message_event"
require_relative "closeyourit/events/slow_query_event"
require_relative "closeyourit/events/slow_method_event"
require_relative "closeyourit/events/log_event"
require_relative "closeyourit/events/performance_issue_event"
require_relative "closeyourit/events/job_metric_event"
require_relative "closeyourit/performance/request_profile"
require_relative "closeyourit/performance/rollup"
require_relative "closeyourit/log_device"
require_relative "closeyourit/log_buffer"
require_relative "closeyourit/usage_registry"
require_relative "closeyourit/subscribers/slow_query"
require_relative "closeyourit/subscribers/request_performance"
require_relative "closeyourit/subscribers/job_performance"
require_relative "closeyourit/instrumenter"
require_relative "closeyourit/monitor"
require_relative "closeyourit/client"
require_relative "closeyourit/rails/capture_exceptions"
require_relative "closeyourit/rails/request_context"
require_relative "closeyourit/rails/request_body"
require_relative "closeyourit/rails/log_broadcast"
require_relative "closeyourit/rails/net_http_patch"
require_relative "closeyourit/rails/active_job_extension"
require_relative "closeyourit/rails/error_subscriber"
require_relative "closeyourit/sidekiq/error_handler"
require_relative "closeyourit/sidekiq/job_metrics_middleware"
require_relative "closeyourit/open_dashboard"

# CloseYourIt — telemetry client (errors + slow query/method statistics)
# that sends events to the CloseYourIt ingest endpoint.
#
# Gem entry point (hyphenated file name, like `sentry-ruby`):
# `require "closeyourit-ruby"` loads the `CloseYourIt` module.
module CloseYourIt
  # Internal base exception: used to avoid loops (our own exceptions are never captured).
  class Error < StandardError; end

  CAPTURED_FLAG = :@__closeyourit_captured

  # Thread-local flag meaning "already inside the diagnostic hook": it stops a notification emitted
  # INSIDE the hook (or by code it calls) from re-entering and re-running the hook → no
  # self-monitoring loop (CYRB-12). It is per-thread because the stages run on different threads
  # (worker pool for send/timeout, calling thread for enqueue/drop).
  DIAGNOSTIC_GUARD = :__closeyourit_in_diagnostic

  class << self
    # Configures the client. Without token/endpoint → no-op.
    #
    # A re-init first SHUTS DOWN the client and log buffer of the previous configuration (CYRB-10):
    # just clearing them would orphan the worker pool thread and the buffer's TimerTask, and events
    # still queued would be lost or flushed late by the orphan timer with the old credential. It
    # reuses the end-of-life semantics of #shutdown (buffer flush → worker drain with timeout,
    # CYRB-5), so the previous queue is drained predictably with its own config.
    # Idempotent: on the first init (or with no captured events) @client/@log_buffer are nil → no-op.
    def init
      shutdown
      @configuration = Configuration.new
      @client = nil
      @log_buffer = nil
      @usage_registry = nil
      @shutdown_notified = false # new session: :shutdown can be notified again
      yield(@configuration) if block_given?
      @configuration.validate!
      register_shutdown_flush
      @configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def configured?
      !@configuration.nil?
    end

    def enabled?
      configuration.enabled?
    end

    # Captures an exception and sends it (fire-and-forget). No-op when disabled,
    # or when the exception is excluded or already captured.
    def capture_exception(exception, handled: false, level: "error", contexts: nil)
      return nil if in_diagnostic?
      return nil unless enabled?
      return nil if ignored_exception?(exception)
      return nil if exception_captured?(exception)

      mark_captured(exception)
      return record_drop(:sampled) unless sampled?

      event = ErrorEvent.from_exception(
        exception, configuration: configuration, handled: handled, level: level, contexts: contexts
      )
      client.capture_event(event)
    end

    # Sends an already built event (slow_query/slow_method).
    def capture_event(event)
      return nil if in_diagnostic?
      return nil unless enabled?

      client.capture_event(event)
    end

    # Sends an explicit diagnostic message (not an exception). Subject to sampling + scope.
    #   CloseYourIt.capture_message("cache miss storm", level: "warning")
    def capture_message(message, level: "info")
      return nil if in_diagnostic?
      return nil unless enabled?
      return record_drop(:sampled) unless sampled?

      event = MessageEvent.new(message, level: level, configuration: configuration)
      client.capture_event(event)
    end

    # Times a block and sends a slow_method if it exceeds the threshold.
    #   CloseYourIt.measure("checkout.total") { ... }
    def measure(label, &block)
      Instrumenter.measure(label, &block)
    end

    # --- Per-request/job scope (user/tags/extra/contexts) ---
    # They enrich the current event; reset at the end of the request/job by middleware and extensions.

    def set_user(attributes)
      Scope.current.set_user(attributes)
    end

    def set_tag(key, value)
      Scope.current.set_tag(key, value)
    end

    def set_tags(attributes)
      Scope.current.set_tags(attributes)
    end

    def set_context(key, attributes)
      Scope.current.set_context(key, attributes)
    end

    def set_extra(key, value)
      Scope.current.set_extra(key, value)
    end

    def configure_scope
      yield(Scope.current) if block_given?
    end

    def clear_scope
      Scope.reset!
    end

    # Adds a context breadcrumb (query, navigation, custom event) to the current event.
    # No-op when breadcrumbs are disabled; `data` is scrubbed (denylist) before being stored.
    def add_breadcrumb(message: nil, category: nil, type: "default", level: "info", data: {})
      return nil unless configuration.breadcrumbs_enabled

      scrubbed = data.nil? || data.empty? ? data : Scrubber.new(configuration).filter_params(data)
      Scope.current.add_breadcrumb(
        Breadcrumb.new(message: message, category: category, type: type, level: level, data: scrubbed)
      )
    end

    # The gem's internal logger (diagnostic warnings/errors on stdout). It is NOT application logging:
    # to send structured logs to CloseYourIt use `CloseYourIt.log` / `CloseYourIt.logger`.
    def internal_logger
      @internal_logger ||= default_internal_logger
    end

    attr_writer :internal_logger

    # Logger-compatible application logger: forwards every message to `CloseYourIt.log` (→ ingest /logs).
    #   CloseYourIt.logger.info("ordine creato", order_id: 1)
    def logger
      @app_logger ||= LogDevice.new
    end

    # Explicit API: builds and buffers a structured log entry (batched to /logs, fire-and-forget).
    # `level` is normalized to the canonical levels (`:warn`→`warning`, downcase; unknown→`info`).
    # The `logger:` keyword = name of the log source; every other keyword is a data attribute.
    # Logs below `logs_min_level` are dropped with the same numeric map as dart/js
    # (standardize, not adapt rule — CYRB-6): nothing is built or sent.
    #   CloseYourIt.log(:info, "ordine creato", order_id: 1)
    #   CloseYourIt.log(:warn, "retry", logger: "payments", attempt: 3)
    def log(level, message, logger: nil, **attributes)
      emit_log(level, message, source: logger, attributes: attributes)
    end

    # Low-level path (gating + building + buffer) with SEPARATE, unambiguous source and attributes:
    # used by `LogDevice` to treat a `logger` key as a data attribute (never as the source) and to set
    # the source only via `.named` (child logger, dart/js parity — CYRB-8).
    # Apps use `CloseYourIt.log` / `CloseYourIt.logger`.
    def emit_log(level, message, source: nil, attributes: {})
      return nil if in_diagnostic?
      return nil unless logs_enabled?
      return nil if log_below_min_level?(level)
      return record_drop(:sampled) unless logs_sampled?

      event = LogEvent.new(message, level: level, attributes: attributes,
                                    logger: source, configuration: configuration)
      log_buffer.add(event)
      nil
    end

    # True when logs are active (master switch + flag): used by LogDevice to NOT evaluate expensive
    # blocks (`logger.debug { dump }`) when logging is off.
    def logs_active?
      logs_enabled?
    end

    # True when a line of the Rails.logger broadcast must be dropped: it names an exception already
    # listed in `excluded_exceptions`, or it matches `excluded_log_patterns`.
    #
    # Needed because an exception excluded from the ERRORS channel came back through the LOGS one:
    # Rails records it with `logger.error`, the broadcast forwarded the line without looking at it,
    # and the noise `excluded_exceptions` had just dropped reappeared as a log entry. On 2026-07-30
    # it was 48,000 entries out of 49,985 in the stream, almost all `ActionController::RoutingError`
    # from missing favicons and bot scans — which has been in the default list from day one (CYRB-17).
    #
    # `ignored_exception?` does not apply: here the class arrives as TEXT inside the message, not as
    # an object with `ancestors` to compare. Hence the substring match on String matchers.
    #
    # It applies ONLY to the automatic Rails.logger mirror: a `CloseYourIt.log` written on purpose by
    # the developer is never silenced (whoever writes it has already decided they want that line).
    def ignored_log_message?(text)
      text = text.to_s
      return false if text.empty?

      config = configuration
      named = config.excluded_exceptions.any? do |matcher|
        if matcher.is_a?(Regexp)
          matcher.match?(text)
        else
          # An empty matcher would match any line: never silence everything because of a dirty list.
          !matcher.empty? && text.include?(matcher)
        end
      end

      named || config.excluded_log_patterns.any? { |pattern| pattern.match?(text) }
    end

    # Forces sending of buffered logs (also called at process shutdown).
    def flush_logs
      @log_buffer&.flush
      nil
    end

    # End-of-life flush: empties the buffered logs AND drains the async worker, waiting (up to a short
    # timeout) for in-flight sends to the ingest to complete. Only flushing the buffer would queue
    # them in the worker, which is then killed on termination → lost logs (CYRB-5). It drains the
    # WHOLE worker (logs + errors + fire-and-forget metrics), not only logs. Registered on at_exit by
    # CloseYourIt.init; with `config.trap_signals` it is also reached on SIGTERM. Idempotent: calling
    # it again is safe (buffer already empty, worker already stopped → no-op).
    def shutdown
      # Order matters: buffers first (they queue the last batch in the worker), then the worker (drains them).
      @usage_registry&.shutdown
      @log_buffer&.shutdown
      @client&.shutdown
      # End-of-life summary: the app receives the counters snapshot without noisy logs. Emitted once
      # per session (an explicit shutdown followed by the at_exit must not duplicate it; the flag is
      # reset on every init). The snapshot is best-effort: sends still in flight beyond the short
      # drain timeout may not be reflected — the drain does not block exit (CYRB-5).
      unless @shutdown_notified
        @shutdown_notified = true
        notify_diagnostic(:shutdown, stats: stats.to_h)
      end
      nil
    end

    # Restores the sending resources in a child process after a fork. Call it from the worker hooks of
    # forking servers (Puma `on_worker_boot`, Sidekiq/Unicorn `after_fork`) to recreate the worker pool
    # and log buffer in the child RIGHT AWAY, instead of waiting for lazy detection on the first event.
    # Optional: the gem detects the PID change on its own anyway (see #ensure_current_process!).
    # Idempotent and safe even if client/buffer were not materialized yet (→ no-op, created lazily).
    def after_fork
      discard_inherited_client!
      @pid = Process.pid
      nil
    end

    # Client diagnostic counters (enqueued/dropped/sent/failed/timeout).
    #   CloseYourIt.stats.to_h # => { enqueued: …, dropped: …, sent: …, failed: …, timeout: … }
    def stats
      @stats ||= Stats.new
    end

    # Notifies a stage of an event's lifecycle to the `on_diagnostic` hook (if configured).
    # `event` is one of :enqueue, :send, :drop, :timeout, :shutdown; `details` a Hash free of
    # sensitive data (e.g. `{ reason: :queue_full }`, `{ status: 429 }`). Called by Client/Transport/
    # BackgroundWorker/LogBuffer. Guarantees (CYRB-12):
    #   * it does NOT send telemetry: it only touches the app hook and the in-memory counters;
    #   * it does NOT trigger self-monitoring loops: during the hook the guard is raised, and while it
    #     is raised BOTH nested `notify_diagnostic` calls AND the telemetry APIs (`capture_*`/log, see
    #     #in_diagnostic?) are suppressed. Since telemetry enqueueing is synchronous on the hook's
    #     thread (only the HTTP send is async), suppressing enqueueing closes the loop cross-thread too;
    #   * it does NOT raise: a faulty hook is isolated (logs to internal_logger), never propagated.
    # The hook always sees the CURRENT configuration: an in-flight notification completing after a
    # re-init reaches the new hook (best-effort, consistent with the fire-and-forget model).
    def notify_diagnostic(event, **details)
      hook = configuration.on_diagnostic
      return nil if hook.nil?
      return nil if Thread.current[DIAGNOSTIC_GUARD]

      Thread.current[DIAGNOSTIC_GUARD] = true
      begin
        hook.call(event, details)
      rescue StandardError => e
        internal_logger.error("CloseYourIt diagnostic hook: #{e.class}: #{e.message}")
      ensure
        Thread.current[DIAGNOSTIC_GUARD] = false
      end
      nil
    end

    # CYSK-29 — the usage telemetry registry (one lookup + increment on the hot path).
    def usage_registry
      ensure_current_process!
      @usage_registry ||= UsageRegistry.new(client: client, configuration: configuration)
    end

    # CYSK-29 — declares that a piece of code was EXECUTED. `key` must be a LITERAL string (never
    # interpolated with data): it is the only honest way to answer "is this branch ever taken?".
    # No-op when the gem is not configured or usage_enabled is OFF.
    def used(key)
      return nil unless configured? && enabled?

      usage_registry.record("custom", key)
      nil
    end

    private

    # True when the current thread is running the diagnostic hook: the telemetry APIs become no-ops
    # so a (badly written) hook cannot generate more telemetry and trigger self-monitoring.
    def in_diagnostic?
      Thread.current[DIAGNOSTIC_GUARD] == true
    end

    # Records a drop: increments the aggregate `dropped` counter and notifies `:drop` with the reason
    # (queue_full/before_send/sampled/error). A single place keeps snapshot and hook aligned.
    def record_drop(reason, **details)
      stats.increment(:dropped)
      notify_diagnostic(:drop, reason: reason, **details)
      nil
    end

    def client
      ensure_current_process!
      @client ||= Client.new(configuration)
    end

    def log_buffer
      ensure_current_process!
      @log_buffer ||= LogBuffer.new(client: client, configuration: configuration)
    end


    # Detects a fork by comparing the PID of the process where @client/@log_buffer were materialized
    # with the current one. In a forked child both objects are inherited from the parent, but their
    # threads — the Client worker pool and the LogBuffer TimerTask — live only in the parent (fork
    # copies only the calling thread): queued events would never leave, being left to threads that
    # exist only in the parent. On a PID change we drop the inherited references WITHOUT #shutdown
    # (no join is possible on the parent's threads, and a buffer flush would resend the parent's
    # events) → the getters recreate them lazily under the current process. The parent is unchanged.
    def ensure_current_process!
      pid = Process.pid
      return if @pid == pid

      discard_inherited_client! if @pid # not on first materialization (@pid nil): nothing to drop
      @pid = pid
    end

    # Releases the client and log buffer references without draining them. Used both by lazy fork
    # detection and by #after_fork: in the child the underlying threads do not exist, so there is
    # nothing to join and nothing must be flushed (it would resend the parent's events). GC collects
    # the old objects; the getters create new ones on the next access.
    def discard_inherited_client!
      @client = nil
      @log_buffer = nil
      @usage_registry = nil
    end

    # Logs follow the client master switch + their own dedicated flag.
    def logs_enabled?
      enabled? && configuration.logs_enabled
    end

    # Threshold gating: the log is dropped when its severity is below `logs_min_level`. Severity is
    # LogEvent's numeric map (debug=0 … fatal=4), identical across SDKs → filters like dart/js.
    def log_below_min_level?(level)
      LogEvent.severity(level) < LogEvent.severity(configuration.logs_min_level)
    end

    # Independent log sampling (1.0 = all, 0.0 = none).
    def logs_sampled?
      rate = configuration.logs_sample_rate.to_f
      return true if rate >= 1.0
      return false if rate <= 0.0

      Random.rand < rate
    end

    # At process shutdown, empties the buffered logs and drains the async worker. Without it, the
    # sub-batch logs of short processes (rake/CLI) and the last queued events would be lost on exit.
    # With `config.trap_signals` it also intercepts SIGTERM, which skips at_exit by default
    # (deploy/Kamal would lose the flush). See #shutdown (CYRB-5).
    #
    # The at_exit is registered once per process (@shutdown_registered avoids N flushes from multiple
    # inits), but the SIGTERM trap is evaluated BEFORE the guard and on EVERY init: it must follow the
    # CURRENT config, otherwise an init enabling `trap_signals` after a first one with the flag OFF
    # would never install it (the idempotency guard would return first). `Signal.trap` is idempotent
    # → reinstalling the same handler is harmless.
    def register_shutdown_flush
      install_term_trap if configuration.trap_signals

      return if @shutdown_registered

      @shutdown_registered = true
      at_exit { shutdown }
    end

    # SIGTERM ends the process WITHOUT running at_exit → the end-of-life flush would not run.
    # We turn TERM into a clean exit: `exit` raises SystemExit on the main thread, which RUNS the
    # at_exit hooks (including #shutdown) in normal context — no heavy work in the trap handler
    # (Mutex/wait_for_termination in trap context would raise ThreadError). Opt-in: it overrides any
    # TERM handler of the host app.
    def install_term_trap
      Signal.trap("TERM") { exit }
    rescue ArgumentError, RuntimeError => e
      # Contexts where TERM cannot be trapped (platform without TERM, non-main thread): not fatal,
      # the at_exit still covers normal exits.
      internal_logger.warn("CloseYourIt: SIGTERM trap not installed (#{e.class}: #{e.message})")
    end

    def ignored_exception?(exception)
      return true if exception.is_a?(CloseYourIt::Error)

      names = exception.class.ancestors.grep(Class).map(&:name).compact
      configuration.excluded_exceptions.any? do |matcher|
        if matcher.is_a?(Regexp)
          names.any? { |name| matcher.match?(name) } || matcher.match?(exception.message.to_s)
        else
          names.include?(matcher)
        end
      end
    end

    # Probabilistic sampling: 1.0 always sends, 0.0 never, in between via Random.rand.
    def sampled?
      rate = configuration.sample_rate.to_f
      return true if rate >= 1.0
      return false if rate <= 0.0

      Random.rand < rate
    end

    def exception_captured?(exception)
      exception.instance_variable_defined?(CAPTURED_FLAG)
    end

    def mark_captured(exception)
      exception.instance_variable_set(CAPTURED_FLAG, true)
    end

    def default_internal_logger
      ::Logger.new($stdout).tap do |l|
        l.level = ::Logger::WARN
        l.progname = "CloseYourIt"
      end
    end
  end
end

# Automatic Rails integration (only when Rails is present).
require_relative "closeyourit/rails/railtie" if defined?(::Rails::Railtie)
