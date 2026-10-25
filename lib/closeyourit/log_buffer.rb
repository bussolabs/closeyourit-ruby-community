# frozen_string_literal: true

require "concurrent"

module CloseYourIt
  # Thread-safe in-memory log buffer: collects LogEvents and flushes them in batches to /logs when
  # they reach `logs_batch_size`, when `logs_flush_interval` expires (timer), or at shutdown.
  # Cuts HTTP requests — logs are high-volume, unlike one-to-one errors/metrics.
  class LogBuffer
    attr_reader :timer # exposed for tests (checks the configured interval)

    def initialize(client:, configuration:)
      @client = client
      @configuration = configuration
      @mutex = Mutex.new
      @events = []
      @timer = nil
    end

    def add(event)
      reached_batch = false
      @mutex.synchronize do
        @events << event
        ensure_timer
        reached_batch = @events.size >= @configuration.logs_batch_size.to_i
      end
      flush if reached_batch
    end

    def flush
      batch = drain
      return if batch.empty?

      @client.flush_logs(batch)
    rescue StandardError => e
      # The flush runs both on the request thread (full batch) and on the timer thread: a to_h /
      # before_send raising on ONE event must not propagate into the app nor kill the TimerTask
      # (which would otherwise stop flushing → logs pile up and are lost). Swallowed and logged.
      CloseYourIt.internal_logger.error("CloseYourIt log buffer: #{e.class}: #{e.message}")
      # The batch has already been drained: if flush_logs raises, those logs are lost. Count them as
      # drops so the failure is not silent (CYRB-12). `batch.to_a` is nil-safe.
      batch.to_a.size.times do
        CloseYourIt.stats.increment(:dropped)
        CloseYourIt.notify_diagnostic(:drop, reason: :error)
      end
    end

    def shutdown
      @timer&.shutdown
      flush
    end

    private

    def drain
      @mutex.synchronize do
        events = @events
        @events = []
        events
      end
    end

    # Starts the periodic flush timer on the first entry (only once).
    def ensure_timer
      return if @timer

      interval = @configuration.logs_flush_interval.to_f
      return if interval <= 0

      @timer = Concurrent::TimerTask.new(execution_interval: interval) { flush }
      @timer.execute
    end
  end
end
