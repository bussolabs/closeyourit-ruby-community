# frozen_string_literal: true

require "concurrent"

module CloseYourIt
  # Runs the send fire-and-forget. With `threads == 0` it runs synchronously (test/dev);
  # otherwise it uses a thread pool with a bounded queue and `fallback_policy: :discard`
  # (when the queue is full the event is lost, never backpressure on the request).
  class BackgroundWorker
    attr_reader :executor

    def initialize(threads:, max_queue: 30)
      @executor = build_executor(threads.to_i, max_queue)
    end

    # Returns true if the event was accepted (or run synchronously), false if dropped
    # because the queue was full (`fallback_policy: :discard`). Never backpressure on the request.
    def perform(&block)
      accepted = @executor.post do
        block.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Never propagate: telemetry must not be able to crash the host app.
        CloseYourIt.internal_logger.error("CloseYourIt background worker: #{e.class}: #{e.message}")
      end

      unless accepted
        CloseYourIt.stats.increment(:dropped)
        CloseYourIt.internal_logger.warn("CloseYourIt background worker: queue full, event dropped")
        CloseYourIt.notify_diagnostic(:drop, reason: :queue_full)
      end

      accepted
    end

    # Drains the queue waiting up to `timeout` seconds. The default is the duration cap of ONE POST
    # (Transport::MAX_REQUEST_SECONDS): waiting less abandons still healthy sends, which is what
    # happened with the old fixed one second (CYRB-24). If the drain expires, the tasks left in the
    # queue are lost: count them as `dropped`, otherwise the end-of-life snapshot reports zero losses.
    def shutdown(timeout = Transport::MAX_REQUEST_SECONDS)
      return unless @executor.respond_to?(:shutdown)

      @executor.shutdown
      terminated = @executor.wait_for_termination(timeout)
      report_abandoned(timeout) unless terminated
      terminated
    end

    private

    # Tasks queued and never run when the drain expired. `queue_length` does not exist on the
    # ImmediateExecutor (synchronous, no queue) → zero left over.
    def report_abandoned(timeout)
      abandoned = @executor.respond_to?(:queue_length) ? @executor.queue_length.to_i : 0
      CloseYourIt.internal_logger.warn(
        "CloseYourIt background worker: drain expired after #{timeout}s, #{abandoned} events abandoned"
      )
      abandoned.times do
        CloseYourIt.stats.increment(:dropped)
        CloseYourIt.notify_diagnostic(:drop, reason: :shutdown_timeout)
      end
    end

    def build_executor(threads, max_queue)
      return Concurrent::ImmediateExecutor.new if threads <= 0

      Concurrent::ThreadPoolExecutor.new(
        min_threads: 0,
        max_threads: threads,
        max_queue: max_queue,
        fallback_policy: :discard
      )
    end
  end
end
