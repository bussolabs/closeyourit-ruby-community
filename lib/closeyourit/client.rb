# frozen_string_literal: true

module CloseYourIt
  # Combines Transport + BackgroundWorker: applies `before_send` and dispatches
  # the send fire-and-forget.
  class Client
    # Log cap per single request to /logs. The backend rejects a batch beyond this limit
    # (413 R413-LOG-002) dropping the WHOLE request — and the buffer has already been drained → lost
    # logs. Must stay ≤ the server limit (backend LOGS_MAX_BATCH = 1000). See #flush_logs.
    LOGS_MAX_BATCH = 1000

    def initialize(configuration)
      @configuration = configuration
      @transport = Transport.new(configuration)
      @worker = BackgroundWorker.new(
        threads: configuration.async_threads,
        max_queue: configuration.background_worker_max_queue
      )
    end

    def capture_event(event)
      payload = event.to_h
      payload = @configuration.before_send.call(payload) if @configuration.before_send
      if payload.nil?
        # before_send dropped the event (returned nil): an intentional drop, made visible (CYRB-12).
        CloseYourIt.stats.increment(:dropped)
        CloseYourIt.notify_diagnostic(:drop, reason: :before_send)
        return nil
      end

      path = event.ingest_path(@configuration.project_id)
      accepted = @worker.perform { @transport.send_event(payload, path: path) }
      if accepted
        CloseYourIt.stats.increment(:enqueued)
        CloseYourIt.notify_diagnostic(:enqueue, path: path)
      end
      payload
    rescue StandardError => e
      # Telemetry must NEVER propagate into the host app's path: capture_event is called by the
      # sql.active_record subscriber, which runs on the query's thread. to_h (scrubber on a malformed
      # bind) and before_send are evaluated here synchronously → if they raise, we absorb, log and
      # drop the event instead of disturbing the host query. See CYRB-2.
      CloseYourIt.internal_logger.error("CloseYourIt client: #{e.class}: #{e.message}")
      CloseYourIt.stats.increment(:dropped)
      CloseYourIt.notify_diagnostic(:drop, reason: :error, error: e.class.name)
      nil
    end

    # Sends a batch of logs as an ARRAY to /logs (the endpoint accepts a single item or an array).
    # before_send is applied to each payload; dropped ones (nil) are not sent. Payloads beyond
    # LOGS_MAX_BATCH are split into several sequential POSTs (one chunk = one POST), so a large flush
    # is not rejected as a whole by the backend and lost — see R3 / LOGS_MAX_BATCH. A flush within
    # the limit stays a single POST.
    def flush_logs(events)
      return nil if events.nil? || events.empty?

      payloads = events.filter_map { |event| build_log_payload(event) }
      return nil if payloads.empty?

      path = events.first.ingest_path(@configuration.project_id)
      payloads.each_slice(LOGS_MAX_BATCH) do |chunk|
        accepted = @worker.perform { @transport.send_event(chunk, path: path) }
        next unless accepted

        CloseYourIt.stats.increment(:enqueued)
        CloseYourIt.notify_diagnostic(:enqueue, path: path, batch: chunk.size)
      end
      payloads
    end

    # CYSK-29 — the usage telemetry flush: ONE POST per window, a payload free of user data by
    # construction (route = Controller#action). Fire-and-forget via the worker, like everything else.
    def flush_usage(symbols:, truncated:, window_started_at:, window_ended_at:)
      payload = {
        environment: @configuration.environment.to_s,
        release: @configuration.release,
        sdk: { name: "closeyourit-ruby", version: CloseYourIt::VERSION },
        window_started_at: window_started_at, window_ended_at: window_ended_at,
        truncated: truncated, symbols: symbols
      }
      path = "/api/v1/projects/#{@configuration.project_id}/usages"
      accepted = @worker.perform { @transport.send_event(payload, path: path) }
      CloseYourIt.notify_diagnostic(:enqueue, path: path, batch: symbols.size) if accepted
      payload
    end

    def shutdown
      @worker.shutdown(@configuration.shutdown_timeout)
    end

    private

    # Builds the payload of ONE log entry. `to_h` (scrubber on a non-UTF-8 byte) and `before_send`
    # may raise: here the buffer has already been drained, so a single broken entry evaluated together
    # with the others would take the whole batch of healthy entries with it. Each entry is isolated
    # and dropped on its own, like the JS client does (CYRB-24). `nil` = entry not to send, already counted.
    def build_log_payload(event)
      payload = event.to_h
      payload = @configuration.before_send.call(payload) if @configuration.before_send
      return payload unless payload.nil?

      # Intentional before_send drop: counted as in #capture_event, otherwise it would silently
      # disappear from the counters (CYRB-12).
      CloseYourIt.stats.increment(:dropped)
      CloseYourIt.notify_diagnostic(:drop, reason: :before_send)
      nil
    rescue StandardError => e
      CloseYourIt.internal_logger.error("CloseYourIt client: log dropped — #{e.class}: #{e.message}")
      CloseYourIt.stats.increment(:dropped)
      CloseYourIt.notify_diagnostic(:drop, reason: :error, error: e.class.name)
      nil
    end
  end
end
