# frozen_string_literal: true

require "time"
require_relative "../events/job_metric_event"
require_relative "../job_context"

module CloseYourIt
  module Subscribers
    # Measures execution duration and queue wait (queue latency) of background jobs — ActiveJob and
    # Sidekiq — and, beyond the configured thresholds, emits performance_issue metrics (subtypes
    # `slow_job` and `job_queue_latency`). PURE logic WITHOUT shared state: everything comes in as
    # parameters, so concurrent jobs on the same thread/process do not contaminate each other. The
    # wiring to ActiveSupport::Notifications and the Sidekiq middleware lives elsewhere (Railtie /
    # JobMetricsMiddleware). Honors the `monitor_jobs` master switch, the thresholds and `jobs_sample_rate`.
    class JobPerformance
      REGISTRY_LOCK = Mutex.new
      ACTIVE_JOB_SUBSCRIBERS = []

      def self.active_job_installed?
        REGISTRY_LOCK.synchronize { !ACTIVE_JOB_SUBSCRIBERS.empty? }
      end
      def initialize(configuration = nil)
        @configuration = configuration
      end

      def install
        REGISTRY_LOCK.synchronize do
          return self if @subscriptions || !ACTIVE_JOB_SUBSCRIBERS.empty?

          @subscriptions = []
          { "enqueue_retry" => :retry, "retry_stopped" => :exhausted, "discard" => :discarded }.each do |name, outcome|
            subscribe(name) { |event| event.payload[:job]&.instance_variable_set(:@__closeyourit_job_outcome, outcome) }
          end
          subscribe("perform_start") { |event| active_job_started(event.payload[:job]) if event.payload[:job] }
          subscribe("perform") do |event|
            job = event.payload[:job]
            if job
              CloseYourIt.usage_registry.record("job", job.class.name) if CloseYourIt.enabled?
              active_job_performed(job, event.duration, payload: event.payload)
            end
          end
          ACTIVE_JOB_SUBSCRIBERS << self
          self
        end
      end

      def uninstall
        Array(@subscriptions).each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
        @subscriptions = nil
        REGISTRY_LOCK.synchronize { ACTIVE_JOB_SUBSCRIBERS.delete(self) }
      end

      # Single decision point: from the measured values (duration and/or wait) it builds 0..2 metrics,
      # applies the thresholds (strict `>`, so X makes no noise and X+1 does) and sampling, then sends
      # them fire-and-forget. `duration_ms` and `queue_latency_ms` are optional: ActiveJob provides them
      # from two separate hooks (perform_start → wait, perform → duration), Sidekiq both in one call.
      # Sampling is applied ONLY to candidates already beyond the threshold (normal jobs neither
      # consume nor generate anything).
      def record(job_class:, queue: nil, adapter: nil, duration_ms: nil, queue_latency_ms: nil,
                 attempt: nil, trace_id: nil, job_context: nil)
        config = configuration
        return unless config.monitor_jobs

        common = { job_class: job_class, queue: queue, adapter: adapter, attempt: attempt, trace_id: trace_id, job_context: job_context }
        events = []
        events << build(config, "slow_job", duration_ms, common) if slow?(config, duration_ms)
        events << build(config, "job_queue_latency", queue_latency_ms, common) if waited?(config, queue_latency_ms)
        return if events.empty?
        return unless sampled?(config)

        events.each { |event| CloseYourIt.capture_event(event) }
        nil
      end

      # `perform_start.active_job` hook: the queue wait is known as soon as the job starts (now - the
      # moment it was due to run).
      def active_job_started(job, now: Time.now.utc)
        context = JobContext.build(framework: "active_job", name: job.class.name,
          queue: (job.queue_name if job.respond_to?(:queue_name)), job_id: (job.job_id if job.respond_to?(:job_id)),
          attempt: (job.executions if job.respond_to?(:executions)), enqueued_at: enqueued_at(job),
          scheduled_at: (job.scheduled_at if job.respond_to?(:scheduled_at)), started_at: now)
        job.instance_variable_set(:@__closeyourit_job_context, context)
        record(
          job_class: job.class.name,
          queue: (job.queue_name if job.respond_to?(:queue_name)),
          adapter: "active_job",
          queue_latency_ms: context["queue_wait_ms"],
          attempt: (job.executions if job.respond_to?(:executions)),
          trace_id: (job.job_id if job.respond_to?(:job_id)), job_context: context
        )
      end

      # `perform.active_job` hook: at the end of execution the duration is `event.duration` (ms).
      def active_job_performed(job, duration_ms, payload: {})
        context = job.instance_variable_get(:@__closeyourit_job_context)
        if context
          outcome, terminal = active_job_outcome(job, payload)
          context = context.merge("duration_ms" => duration_ms, "attempt_outcome" => outcome, "terminal" => terminal)
          JobContext.log(context, configuration)
        end
        record(
          job_class: job.class.name,
          queue: (job.queue_name if job.respond_to?(:queue_name)),
          adapter: "active_job",
          duration_ms: duration_ms,
          attempt: (job.executions if job.respond_to?(:executions)),
          trace_id: (job.job_id if job.respond_to?(:job_id)), job_context: context
        )
      ensure
        job.remove_instance_variable(:@__closeyourit_job_context) if job.instance_variable_defined?(:@__closeyourit_job_context)
        job.remove_instance_variable(:@__closeyourit_job_outcome) if job.instance_variable_defined?(:@__closeyourit_job_outcome)
      end

      def active_job_outcome(job, payload)
        outcome = job.instance_variable_get(:@__closeyourit_job_outcome)
        return [ "error", nil ] if payload[:exception_object] || payload[:exception]
        return [ "retry", false ] if outcome == :retry
        return [ "discarded", true ] if outcome == :discarded
        return [ "error", nil ] if outcome == :exhausted
        return [ "unknown", nil ] if outcome == :raised || payload[:aborted]

        [ "success", true ]
      end

      # Normalizes `enqueued_at` (Time, Numeric epoch in seconds like Sidekiq, or ISO8601 String) into
      # a wait (ms) relative to `now`. nil or unparsable → nil: no wait metric (adapter that does not
      # populate the enqueue instant). Clamped to 0 when negative (clock skew, enqueue "in the future"):
      # the ingest schema requires `duration_ms >= 0`.
      def self.latency_ms(enqueued_at, now:)
        started = to_time(enqueued_at)
        return nil if started.nil?

        ms = (now - started) * 1000.0
        ms.negative? ? 0.0 : ms
      end

      def self.to_time(value)
        case value
        when Time    then value
        when Numeric then Time.at(value)
        when String  then parse_time(value)
        end
      end

      def self.parse_time(value)
        Time.parse(value)
      rescue ArgumentError
        nil
      end

      private

      def subscribe(name, &callback)
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("#{name}.active_job") do |*args|
          callback.call(ActiveSupport::Notifications::Event.new(*args))
        rescue StandardError
          CloseYourIt.internal_logger.warn("CloseYourIt job observation failed")
        end
      end

      def enqueued_at(job)
        job.enqueued_at if job.respond_to?(:enqueued_at)
      end

      # A job delayed on purpose (set(wait:), retry_on backoff) is due at scheduled_at, not when it was
      # enqueued: the planned delay is not queue wait (CYRB-27). No enqueued_at still means no metric.
      def due_at(job)
        enqueued = self.class.to_time(enqueued_at(job))
        scheduled = self.class.to_time(job.scheduled_at) if job.respond_to?(:scheduled_at)
        return enqueued if enqueued.nil? || scheduled.nil?

        [ enqueued, scheduled ].max
      end

      def configuration
        @configuration || CloseYourIt.configuration
      end

      def slow?(config, duration_ms)
        duration_ms && config.slow_job_threshold_ms && duration_ms > config.slow_job_threshold_ms
      end

      def waited?(config, latency_ms)
        latency_ms && config.job_queue_latency_threshold_ms &&
          latency_ms > config.job_queue_latency_threshold_ms
      end

      def sampled?(config)
        rate = config.jobs_sample_rate.to_f
        return true if rate >= 1.0
        return false if rate <= 0.0

        Random.rand < rate
      end

      def build(config, subtype, duration_ms, common)
        JobMetricEvent.new(common.merge(subtype: subtype, duration_ms: duration_ms), config)
      end
    end
  end
end
