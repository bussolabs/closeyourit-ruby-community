# frozen_string_literal: true

RSpec.describe CloseYourIt::Client do
  subject(:client) { described_class.new(config) }

  let(:config) do
    CloseYourIt::Configuration.new.tap do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0 # synchronous → HTTP happens during capture_event
    end
  end

  let(:event) do
    instance_double(
      CloseYourIt::ErrorEvent,
      to_h: { "level" => "error" },
      ingest_path: "/api/v1/projects/proj-1/events"
    )
  end

  it "sends the payload to the path given by the event" do
    stub = stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

    client.capture_event(event)

    expect(stub).to have_been_requested
    expect(WebMock).to have_requested(:post, "https://closeyour.it/api/v1/projects/proj-1/events")
      .with(body: { "level" => "error" }.to_json)
  end

  it "applies before_send and uses the transformed payload" do
    config.before_send = ->(payload) { payload.merge("tagged" => true) }
    stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

    result = client.capture_event(event)

    expect(result).to eq("level" => "error", "tagged" => true)
    expect(WebMock).to have_requested(:post, "https://closeyour.it/api/v1/projects/proj-1/events")
      .with(body: { "level" => "error", "tagged" => true }.to_json)
  end

  it "sends nothing when before_send returns nil" do
    config.before_send = ->(_payload) { nil }
    stub = stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

    expect(client.capture_event(event)).to be_nil
    expect(stub).not_to have_been_requested
  end

  it "increments stats.enqueued when the event is accepted" do
    stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

    expect { client.capture_event(event) }.to change { CloseYourIt.stats[:enqueued] }.by(1)
  end

  it "delegates shutdown to the worker" do
    expect { client.shutdown }.not_to raise_error
  end

  # CYRB-2 — capture_event is called inside the sql.active_record subscriber, i.e. on the host
  # query's thread. to_h (scrubber on a malformed bind) and before_send are evaluated SYNCHRONOUSLY
  # here: if they raise, the exception would bubble up into the host query's path. Telemetry must never
  # crash the host → capture_event must absorb the exception, log it and return nil.
  describe "#capture_event — resilience to raising to_h/before_send (CYRB-2)" do
    it "does not propagate when before_send raises: returns nil and sends nothing" do
      config.before_send = ->(_payload) { raise "boom in before_send" }
      stub = stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

      expect { client.capture_event(event) }.not_to raise_error
      expect(client.capture_event(event)).to be_nil
      expect(stub).not_to have_been_requested
    end

    it "does not propagate when event.to_h raises: returns nil and sends nothing" do
      allow(event).to receive(:to_h).and_raise("boom in to_h")
      stub = stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

      expect { client.capture_event(event) }.not_to raise_error
      expect(client.capture_event(event)).to be_nil
      expect(stub).not_to have_been_requested
    end

    it "logs the failure to internal_logger without propagating" do
      config.before_send = ->(_payload) { raise "boom in before_send" }
      logger = instance_double(Logger)
      allow(CloseYourIt).to receive(:internal_logger).and_return(logger)

      expect(logger).to receive(:error).with(/CloseYourIt client/)
      expect { client.capture_event(event) }.not_to raise_error
    end

    it "does not alter the happy path: without exceptions it returns the payload and sends" do
      stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

      expect(client.capture_event(event)).to eq("level" => "error")
      expect(WebMock).to have_requested(:post, "https://closeyour.it/api/v1/projects/proj-1/events")
    end
  end

  # R3 — the backend rejects a log batch beyond LOGS_MAX_BATCH (413 R413-LOG-002) dropping the WHOLE
  # request. The buffer has already been drained → those logs would be lost. flush_logs must split the
  # payloads into chunks ≤ the limit and POST each separately; a flush ≤ the limit stays a single POST.
  describe "#flush_logs — log batch chunking (R3)" do
    let(:transport) { instance_double(CloseYourIt::Transport) }

    before do
      allow(CloseYourIt::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:send_event)
    end

    def log_events(count)
      Array.new(count) do |i|
        instance_double(
          CloseYourIt::LogEvent,
          to_h: { "message" => "log-#{i}" },
          ingest_path: "/api/v1/projects/proj-1/logs"
        )
      end
    end

    it "splits a flush of 1500 events into two POSTs of 1000 and 500" do
      sizes = []
      allow(transport).to receive(:send_event) { |payload, **| sizes << payload.size }

      client.flush_logs(log_events(1500))

      expect(transport).to have_received(:send_event).twice
      expect(sizes).to eq([ 1000, 500 ])
    end

    it "sends a single POST when the flush is exactly at the limit (1000)" do
      client.flush_logs(log_events(1000))
      expect(transport).to have_received(:send_event).once
    end

    it "sends a single POST for a small flush" do
      client.flush_logs(log_events(50))
      expect(transport).to have_received(:send_event).once
    end

    it "POSTs every chunk to the same /logs path" do
      client.flush_logs(log_events(1500))
      expect(transport).to have_received(:send_event)
        .with(anything, path: "/api/v1/projects/proj-1/logs").twice
    end

    it "never exceeds the limit: 2500 events → chunks of 1000, 1000, 500" do
      sizes = []
      allow(transport).to receive(:send_event) { |payload, **| sizes << payload.size }

      client.flush_logs(log_events(2500))

      expect(sizes).to eq([ 1000, 1000, 500 ])
    end

    it "increments stats.enqueued for every queued chunk (reliable diagnostics for logs too)" do
      expect { client.flush_logs(log_events(1500)) }
        .to change { CloseYourIt.stats[:enqueued] }.by(2)
    end

    it "counts logs dropped by before_send (nil) as dropped, making drops visible" do
      config.before_send = ->(payload) { payload["message"] == "log-2" ? nil : payload }

      expect { client.flush_logs(log_events(5)) } # log-2 dropped → 1 drop, 4 enqueued
        .to change { CloseYourIt.stats[:dropped] }.by(1)
        .and change { CloseYourIt.stats[:enqueued] }.by(1)
    end
  end

  # CYRB-24 R2 — payloads were built in bulk (events.map(&:to_h)) outside any rescue, with the buffer
  # already drained: ONE malformed entry made the whole map raise and took the entire batch with it.
  describe "#flush_logs — a broken entry does not take the batch with it (CYRB-24)" do
    let(:transport) { instance_double(CloseYourIt::Transport) }

    before do
      allow(CloseYourIt::Transport).to receive(:new).and_return(transport)
      allow(transport).to receive(:send_event)
    end

    def good_event(message)
      instance_double(
        CloseYourIt::LogEvent,
        to_h: { "message" => message },
        ingest_path: "/api/v1/projects/proj-1/logs"
      )
    end

    def broken_event
      event = instance_double(CloseYourIt::LogEvent, ingest_path: "/api/v1/projects/proj-1/logs")
      allow(event).to receive(:to_h).and_raise(ArgumentError, "non-UTF-8 byte")
      event
    end

    it "sends the good entries and drops only the broken one" do
      allow(CloseYourIt.internal_logger).to receive(:error)
      sent = nil
      allow(transport).to receive(:send_event) { |payload, **| sent = payload }

      client.flush_logs([ good_event("log-alfa"), broken_event, good_event("log-beta") ])

      expect(sent).to eq([ { "message" => "log-alfa" }, { "message" => "log-beta" } ])
    end

    it "counts only the broken entry as dropped" do
      allow(CloseYourIt.internal_logger).to receive(:error)

      expect { client.flush_logs([ good_event("log-alfa"), broken_event, good_event("log-beta") ]) }
        .to change { CloseYourIt.stats[:dropped] }.by(1)
    end

    it "also isolates a before_send raising on a single entry" do
      allow(CloseYourIt.internal_logger).to receive(:error)
      config.before_send = lambda { |payload|
        raise "broken before_send" if payload["message"] == "log-beta"

        payload
      }
      sent = nil
      allow(transport).to receive(:send_event) { |payload, **| sent = payload }

      client.flush_logs([ good_event("log-alfa"), good_event("log-beta"), good_event("log-gamma") ])

      expect(sent).to eq([ { "message" => "log-alfa" }, { "message" => "log-gamma" } ])
    end

    it "does not raise when the broken entry is the first of the batch" do
      allow(CloseYourIt.internal_logger).to receive(:error)
      sent = nil
      allow(transport).to receive(:send_event) { |payload, **| sent = payload }

      expect { client.flush_logs([ broken_event, good_event("log-alfa") ]) }.not_to raise_error
      expect(sent).to eq([ { "message" => "log-alfa" } ])
    end

    it "POSTs nothing when every entry is broken" do
      allow(CloseYourIt.internal_logger).to receive(:error)

      expect(client.flush_logs([ broken_event, broken_event ])).to be_nil
      expect(transport).not_to have_received(:send_event)
    end
  end

  # CYRB-24 R1 — the end-of-life drain must be able to wait as long as one POST, and be configurable.
  describe "#shutdown" do
    it "passes the configured timeout to the worker" do
      config.shutdown_timeout = 7
      worker = client.instance_variable_get(:@worker)
      allow(worker).to receive(:shutdown)

      client.shutdown

      expect(worker).to have_received(:shutdown).with(7)
    end
  end
end
