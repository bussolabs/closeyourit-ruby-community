# frozen_string_literal: true

# CYRB-12 — Make the gem's sends and drops visible. Whoever runs the app must understand whether
# telemetry is enqueued, sent or dropped without enabling noisy logs and without creating
# self-monitoring loops. Two complementary mechanisms, both LOCAL (they send no telemetry):
#   * the counters snapshot (`CloseYourIt.stats.to_h`) — aggregate pull view;
#   * the `on_diagnostic` hook — per-event push view (enqueue/send/drop/timeout/shutdown) with the
#     drop reasons, free of sensitive data.
RSpec.describe "Client diagnostics (CYRB-12)" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }
  let(:events) { [] }

  # Collects the diagnostic events observed by the host app.
  def hook
    ->(event, details) { events << [ event, details ] }
  end

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0 # synchronous: HTTP and diagnostics happen on the test thread
      c.on_diagnostic = hook
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def boom
    raise "boom"
  rescue RuntimeError => e
    e
  end

  def observed(event)
    events.select { |name, _| name == event }
  end

  describe "on_diagnostic hook — lifecycle" do
    it "emits :enqueue when the event is accepted for sending" do
      enable!
      stub_request(:post, url)

      CloseYourIt.capture_exception(boom)

      expect(observed(:enqueue).size).to eq(1)
    end

    it "emits :send with the status on a 2xx response" do
      enable!
      stub_request(:post, url).to_return(status: 202)

      CloseYourIt.capture_exception(boom)

      expect(observed(:send)).to eq([ [ :send, { status: 202 } ] ])
    end

    it "emits :shutdown at termination with the counters snapshot" do
      enable!
      stub_request(:post, url).to_return(status: 202)
      CloseYourIt.capture_exception(boom)

      CloseYourIt.shutdown

      shutdown = observed(:shutdown)
      expect(shutdown.size).to eq(1)
      expect(shutdown.first.last[:stats]).to include(sent: 1)
    end

    it "emits :shutdown only once even with an explicit shutdown followed by at_exit" do
      enable!
      stub_request(:post, url).to_return(status: 202)
      CloseYourIt.capture_exception(boom)

      CloseYourIt.shutdown
      CloseYourIt.shutdown # e.g. at_exit after an explicit app shutdown

      expect(observed(:shutdown).size).to eq(1)
    end
  end

  describe "on_diagnostic hook — drop reasons (free of sensitive data)" do
    it "emits :drop reason :sampled when sampling drops the event" do
      enable!(sample_rate: 0.5)
      allow(Random).to receive(:rand).and_return(0.6) # >= rate → dropped
      stub = stub_request(:post, url)

      CloseYourIt.capture_exception(boom)

      expect(observed(:drop)).to eq([ [ :drop, { reason: :sampled } ] ])
      expect(stub).not_to have_been_requested
      expect(CloseYourIt.stats[:dropped]).to eq(1)
    end

    it "emits :drop reason :before_send when before_send returns nil" do
      enable!(before_send: ->(_payload) { nil })
      stub = stub_request(:post, url)

      CloseYourIt.capture_exception(boom)

      expect(observed(:drop)).to eq([ [ :drop, { reason: :before_send } ] ])
      expect(stub).not_to have_been_requested
      expect(CloseYourIt.stats[:dropped]).to eq(1)
    end

    it "emits :drop reason :error when before_send raises (without propagating)" do
      enable!(before_send: ->(_payload) { raise "boom in before_send" })
      allow(CloseYourIt.internal_logger).to receive(:error)

      expect { CloseYourIt.capture_exception(boom) }.not_to raise_error

      drop = observed(:drop)
      expect(drop.size).to eq(1)
      expect(drop.first.last).to include(reason: :error)
      expect(CloseYourIt.stats[:dropped]).to eq(1)
    end

    it "emits :drop reason :response with the status on 4xx/429/5xx" do
      enable!
      allow(CloseYourIt.internal_logger).to receive(:warn)

      [ 401, 429, 500 ].each do |status|
        events.clear
        stub_request(:post, url).to_return(status:)
        CloseYourIt.capture_exception(boom)
        expect(observed(:drop)).to eq([ [ :drop, { reason: :response, status: } ] ]), "status #{status}"
      end
    end

    it "emits :timeout and increments stats.timeout on a network timeout" do
      enable!
      stub_request(:post, url).to_timeout
      allow(CloseYourIt.internal_logger).to receive(:error)

      expect { CloseYourIt.capture_exception(boom) }.to change { CloseYourIt.stats[:timeout] }.by(1)

      timeout = observed(:timeout)
      expect(timeout.size).to eq(1)
      # A timeout is still a send failure: the aggregate `failed` counter goes up anyway.
      expect(CloseYourIt.stats[:failed]).to eq(1)
    end

    it "emits :drop reason :queue_full when the queue is full (async worker)" do
      CloseYourIt.init { |c| c.on_diagnostic = hook }
      worker = CloseYourIt::BackgroundWorker.new(threads: 1, max_queue: 1)
      allow(CloseYourIt.internal_logger).to receive(:warn)
      started = Queue.new
      gate = Queue.new

      worker.perform { started << :go; gate.pop } # holds the only thread
      started.pop                                 # waits until the task really holds the thread
      worker.perform { :queued }                  # fills the only queue slot
      worker.perform { :overflow }                # queue full → dropped

      expect(observed(:drop)).to eq([ [ :drop, { reason: :queue_full } ] ])
    ensure
      gate << :go
      worker&.shutdown
    end
  end

  describe "non-recursion and no telemetry (self-monitoring loop)" do
    it "emitting a diagnostic event sends no network telemetry by itself" do
      # No stub registered: WebMock (net-connect disabled) would raise if the diagnostic mechanism
      # alone attempted a request. The hook receives the event; no HTTP.
      CloseYourIt.init { |c| c.on_diagnostic = ->(event, _details) { events << event } }

      expect { CloseYourIt.notify_diagnostic(:shutdown, stats: CloseYourIt.stats.to_h) }
        .not_to raise_error
      expect(events).to eq([ :shutdown ])
    end

    it "suppresses telemetry generated INSIDE the hook, async too (no self-monitoring)" do
      # A hook that tries to send more telemetry at every stage: enqueueing happens synchronously on
      # the hook's thread (only the send is async), so the guard suppresses it → no extra POST, no
      # loop, regardless of the number of worker threads.
      loopy = lambda do |event, _details|
        events << event
        CloseYourIt.capture_message("self-telemetry #{event}")
      end
      enable!(async_threads: 2, on_diagnostic: loopy)
      primary = stub_request(:post, url).to_return(status: 202)

      CloseYourIt.capture_exception(boom)
      CloseYourIt.shutdown # drains any in-flight sends

      # Only the original event left: the telemetry attempted by the hook was never enqueued.
      expect(primary).to have_been_requested.once
    end

    it "the non-recursive guard suppresses cascading re-runs of the hook" do
      depth = 0
      max_depth = 0
      nested = lambda do |_event, _details|
        depth += 1
        max_depth = [ max_depth, depth ].max
        # A new notification inside the hook must not re-run the hook (no self-monitoring loop).
        CloseYourIt.notify_diagnostic(:drop, reason: :sampled)
      ensure
        depth -= 1
      end
      CloseYourIt.init { |c| c.on_diagnostic = nested }

      CloseYourIt.notify_diagnostic(:send, status: 202)

      expect(max_depth).to eq(1) # never nested: the inner notification was suppressed by the guard
    end

    it "does not propagate a faulty hook's exception and logs it to internal_logger" do
      enable!(on_diagnostic: ->(*) { raise "broken hook" })
      stub_request(:post, url).to_return(status: 202)
      allow(CloseYourIt.internal_logger).to receive(:error)

      expect { CloseYourIt.capture_exception(boom) }.not_to raise_error
      expect(CloseYourIt.internal_logger).to have_received(:error).with(/diagnostic/i).at_least(:once)
    end

    it "is a no-op when no hook is configured" do
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.async_threads = 0
      end
      stub_request(:post, url).to_return(status: 202)

      expect { CloseYourIt.capture_exception(boom) }.not_to raise_error
    end
  end
end
