# frozen_string_literal: true

RSpec.describe CloseYourIt::BackgroundWorker do
  it "runs the block synchronously when threads == 0" do
    worker = described_class.new(threads: 0, max_queue: 30)
    ran = false

    worker.perform { ran = true }

    expect(ran).to be(true)
  end

  it "does not raise if the block fails (rescue + log)" do
    worker = described_class.new(threads: 0, max_queue: 30)
    allow(CloseYourIt.internal_logger).to receive(:error)

    expect { worker.perform { raise "boom" } }.not_to raise_error
    expect(CloseYourIt.internal_logger).to have_received(:error).with(/boom/)
  end

  it "sets up the queue with fallback_policy :discard (threads > 0)" do
    worker = described_class.new(threads: 2, max_queue: 1)

    expect(worker.executor.fallback_policy).to eq(:discard)
  ensure
    worker&.shutdown
  end

  it "returns true when the block is accepted (synchronous)" do
    worker = described_class.new(threads: 0, max_queue: 30)

    expect(worker.perform { :ok }).to be(true)
  end

  it "drops, logs at warn and increments stats.dropped when the queue is full" do
    worker = described_class.new(threads: 1, max_queue: 1)
    allow(CloseYourIt.internal_logger).to receive(:warn)
    gate = Queue.new

    worker.perform { gate.pop } # holds the only thread until we release it
    worker.perform { :queued }  # fills the only queue slot

    expect { @rejected = worker.perform { :overflow } }
      .to change { CloseYourIt.stats[:dropped] }.by(1)
    expect(@rejected).to be(false)
    expect(CloseYourIt.internal_logger).to have_received(:warn).with(/queue full/)
  ensure
    gate << :go
    worker&.shutdown
  end

  # CYRB-24 R1 — the end-of-life drain waited a fixed 1s, while a single POST can last up to
  # (OPEN+READ) × (1 + MAX_REDIRECTS) = 15s: the last batch was abandoned and the counters
  # reported dropped: 0.
  describe "#shutdown — end-of-life drain (CYRB-24)" do
    it "waits by default for the duration cap of one POST, not one second" do
      worker = described_class.new(threads: 1, max_queue: 5)
      allow(worker.executor).to receive(:wait_for_termination).and_return(true)

      worker.shutdown

      expect(worker.executor).to have_received(:wait_for_termination)
        .with(CloseYourIt::Transport::MAX_REQUEST_SECONDS)
      expect(CloseYourIt::Transport::MAX_REQUEST_SECONDS).to be >= 15
    end

    it "accepts an explicit timeout" do
      worker = described_class.new(threads: 1, max_queue: 5)
      allow(worker.executor).to receive(:wait_for_termination).and_return(true)

      worker.shutdown(0.5)

      expect(worker.executor).to have_received(:wait_for_termination).with(0.5)
    end

    it "counts the tasks left in the queue as dropped when the drain expires" do
      worker = described_class.new(threads: 1, max_queue: 5)
      gate = Queue.new
      allow(CloseYourIt.internal_logger).to receive(:warn)

      worker.perform { gate.pop } # holds the only thread
      worker.perform { :leftover_one }
      worker.perform { :leftover_two }

      expect { worker.shutdown(0.1) }.to change { CloseYourIt.stats[:dropped] }.by(2)
      expect(CloseYourIt.internal_logger).to have_received(:warn).with(/drain/)
    ensure
      gate << :go
    end

    it "counts no drops when the drain completes in time" do
      worker = described_class.new(threads: 1, max_queue: 5)
      worker.perform { :fast }

      expect { worker.shutdown }.not_to change { CloseYourIt.stats[:dropped] }
    end

    it "notifies diagnostics with reason :shutdown_timeout when the drain expires" do
      worker = described_class.new(threads: 1, max_queue: 5)
      gate = Queue.new
      seen = []
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.on_diagnostic = ->(event, details) { seen << [ event, details ] }
      end

      worker.perform { gate.pop }
      worker.perform { :leftover }
      worker.shutdown(0.1)

      expect(seen).to include([ :drop, { reason: :shutdown_timeout } ])
    ensure
      gate << :go
    end
  end
end
