# frozen_string_literal: true

# CYRB-5 — Reliable end-of-life flush. Before the fix `at_exit` only flushed the buffer into the worker
# pool but did NOT wait for the send (no `@client.shutdown`): on the deploy's SIGTERM the sub-batch logs
# stayed queued and were lost when the process ended. `CloseYourIt.shutdown` must flush the buffer AND
# drain the worker (wait_for_termination), and `init` can optionally intercept SIGTERM (which skips
# at_exit by default).
RSpec.describe "CloseYourIt.shutdown — end-of-life flush + worker drain (CYRB-5)" do
  let(:logs_url) { "https://closeyour.it/api/v1/projects/proj-1/logs" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0        # synchronous by default in tests; async cases override it
      c.logs_batch_size = 50
      c.logs_flush_interval = 0  # no timer: flush happens only on batch or at shutdown
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  after { CloseYourIt.clear_scope }

  describe "#shutdown" do
    it "drains the worker (client.shutdown) AFTER flushing the buffer" do
      enable!
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "x") # creates @log_buffer and @client

      buffer = CloseYourIt.instance_variable_get(:@log_buffer)
      client = CloseYourIt.instance_variable_get(:@client)
      order = []
      allow(buffer).to receive(:shutdown).and_wrap_original { |orig, *a| order << :buffer; orig.call(*a) }
      allow(client).to receive(:shutdown).and_wrap_original { |orig, *a| order << :client; orig.call(*a) }

      CloseYourIt.shutdown

      expect(order).to eq(%i[buffer client])
    end

    it "sends and WAITS for buffered sub-batch logs at termination (ticket scenario, async worker)" do
      enable!(async_threads: 2) # real thread pool: without the drain the POST might not complete
      stub_request(:post, logs_url)

      10.times { |i| CloseYourIt.log(:info, "log-#{i}") }
      expect(WebMock).not_to have_requested(:post, logs_url) # 10 < batch 50: still only in the buffer

      CloseYourIt.shutdown

      expect(WebMock).to have_requested(:post, logs_url).with { |req|
        body = JSON.parse(req.body)
        body.is_a?(Array) && body.size == 10 && body.first["message"] == "log-0"
      }
    end

    it "is safe (no-op) when no buffer or client was ever created" do
      enable! # no log/capture: @log_buffer and @client stay nil after init
      expect { CloseYourIt.shutdown }.not_to raise_error
    end

    it "is idempotent: two consecutive shutdowns neither raise nor resend the batch" do
      enable!
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "x")

      CloseYourIt.shutdown
      expect { CloseYourIt.shutdown }.not_to raise_error
      expect(WebMock).to have_requested(:post, logs_url).once
    end
  end

  describe "optional SIGTERM trap" do
    let!(:previous_registration) { CloseYourIt.instance_variable_get(:@shutdown_registered) }

    before do
      # `register_shutdown_flush` is idempotent per process: we reset the flag so `init` runs it again.
      CloseYourIt.instance_variable_set(:@shutdown_registered, nil)
      # Do not register a real at_exit (it would pollute the end of the suite with a spurious flush).
      allow(CloseYourIt).to receive(:at_exit)
    end

    after { CloseYourIt.instance_variable_set(:@shutdown_registered, previous_registration) }

    def init_with(**over)
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        over.each { |key, value| c.public_send("#{key}=", value) }
      end
    end

    it "intercepts NO signal by default (opt-in)" do
      expect(Signal).not_to receive(:trap)
      init_with
    end

    it "installs a SIGTERM handler with trap_signals = true" do
      trapped = []
      allow(Signal).to receive(:trap) { |sig, *| trapped << sig }

      init_with(trap_signals: true)

      expect(trapped).to eq(%w[TERM])
    end

    it "installs the trap on a later init enabling trap_signals after a first one with the flag OFF" do
      # Regression: @shutdown_registered is idempotent for the at_exit (one registration per process),
      # but the trap must follow the CURRENT config — a first init with the flag OFF must not prevent a
      # later one with the flag ON from installing it (otherwise the idempotency guard returns first).
      trapped = []
      allow(Signal).to receive(:trap) { |sig, *| trapped << sig }

      init_with(trap_signals: false)
      expect(trapped).to be_empty

      init_with(trap_signals: true)
      expect(trapped).to eq(%w[TERM])
    end

    it "does not raise (and logs a warning) if the SIGTERM trap cannot be installed on this platform" do
      allow(Signal).to receive(:trap).and_raise(ArgumentError, "unsupported signal")
      allow(CloseYourIt.internal_logger).to receive(:warn)

      expect { init_with(trap_signals: true) }.not_to raise_error
      expect(CloseYourIt.internal_logger).to have_received(:warn).with(/SIGTERM/)
    end
  end
end
