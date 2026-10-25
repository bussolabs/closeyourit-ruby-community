# frozen_string_literal: true

require_relative "../subscribers/job_performance"

module CloseYourIt
  module Sidekiq
    # Sidekiq server middleware (registered by the railtie only when Sidekiq is present) that measures
    # the job's execution duration and queue wait, then delegates emitting over-threshold metrics to
    # Subscribers::JobPerformance. It does not alter the job: it times around `yield` and re-raises
    # any error unchanged (error capture belongs to the ErrorHandler). Measurement happens in `ensure`,
    # so it is taken for jobs that raise too; telemetry is isolated (an error in our code never
    # disturbs the host job). Effectively a no-op when `monitor_jobs` is OFF (the decision lives in #record).
    class JobMetricsMiddleware
      def initialize(subscriber = nil)
        @subscriber = subscriber
      end

      def call(_worker, job, queue)
        return yield if active_job_owned?(job)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        context = observe(job, queue)
        value = yield
        succeeded = true
        value
      ensure
        emit(job, queue, started, context, succeeded) if started
      end

      private

      def active_job_owned?(job)
        %w[ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper Sidekiq::ActiveJob::Wrapper].include?(job["class"]) &&
          Subscribers::JobPerformance.active_job_installed?
      end

      def observe(job, queue)
        # Sidekiq 8 changed the timestamp wire unit; do not infer it from magnitude.
        version = ::Sidekiq::VERSION if defined?(::Sidekiq::VERSION)
        enqueued = JobContext.sidekiq_time(job["enqueued_at"], version: version)
        JobContext.build(framework: "sidekiq", name: job["wrapped"] || job["class"],
          queue: queue || job["queue"], job_id: job["jid"], attempt: attempt(job), retry_count: job["retry_count"],
          enqueued_at: enqueued, started_at: Time.now.utc)
      rescue StandardError
        nil
      end

      def emit(job, queue, started, context, succeeded)
        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        if context
          context = context.merge("duration_ms" => duration_ms, "attempt_outcome" => succeeded ? "success" : "error",
            "terminal" => succeeded ? true : nil)
          JobContext.log(context, CloseYourIt.configuration)
        end
        subscriber.record(
          job_class: job["wrapped"] || job["class"],
          queue: queue || job["queue"],
          adapter: "sidekiq",
          duration_ms: duration_ms,
          queue_latency_ms: context && context["queue_wait_ms"],
          attempt: attempt(job),
          trace_id: job["jid"], job_context: context
        )
      rescue StandardError => e
        CloseYourIt.internal_logger.error("CloseYourIt job metrics: #{e.class}: #{e.message}")
      end

      def subscriber
        @subscriber ||= Subscribers::JobPerformance.new
      end

      # 1-based execution number. Sidekiq does NOT set `retry_count` on the first run (nil), sets it to 0
      # on the first retry, 1 on the second, ... → attempt = retry_count + 2 when present, 1 on the first run.
      def attempt(job)
        count = job["retry_count"]
        count.nil? ? 1 : count + 2
      end
    end
  end
end
