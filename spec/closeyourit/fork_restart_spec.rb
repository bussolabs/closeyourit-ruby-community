# frozen_string_literal: true

require "json"
require "timeout"

# CYRB-11 — Transport recovery after a fork. Ruby servers/workers (Puma cluster, Sidekiq, Unicorn)
# initialize the gem in the master process BEFORE forking the children. The worker pool (threads) and
# the buffer TimerTask do NOT survive the fork: in the child @client/@log_buffer are inherited but point
# to threads that live only in the parent → queued events would never leave. The gem detects the PID
# change (lazily, on first access) and recreates the resources in the child; it also exposes
# CloseYourIt.after_fork for the worker hooks (Puma on_worker_boot, Sidekiq/Unicorn after_fork). The
# inherited references are ABANDONED without shutdown/drain: no join on the parent's threads
# (impossible — they do not exist here) and no flush of the inherited buffer (it would resend parent events).
RSpec.describe "CloseYourIt — transport recovery after a fork (CYRB-11)" do
  after { CloseYourIt.clear_scope }

  # Synchronous init (async_threads: 0) and without timer (logs_flush_interval: 0) by default: the cases
  # needing a real thread pool or timer override the relevant options.
  def init!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.logs_batch_size = 50
      c.logs_flush_interval = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  describe "PID change detection (lazy)" do
    it "reuses the memoized client in the SAME process, not recreating it on every access" do
      init!
      first = CloseYourIt.send(:client)

      expect(CloseYourIt.send(:client)).to equal(first)
    end

    it "recreates the client in a process with a different PID (forked child), without reusing the inherited one" do
      real_pid = Process.pid
      init!
      old_client = CloseYourIt.send(:client) # materialized under real_pid
      allow(old_client).to receive(:shutdown) # spy: it must never be drained in the child

      allow(Process).to receive(:pid).and_return(real_pid + 1) # simulates the child PID

      new_client = CloseYourIt.send(:client)

      expect(new_client).not_to equal(old_client)
      # "no impossible join": the inherited client is abandoned, never #shutdown (which would drain a
      # worker pool whose threads do not exist in this process).
      expect(old_client).not_to have_received(:shutdown)
    end

    it "also recreates the log buffer in a process with a different PID, without flushing the inherited one" do
      real_pid = Process.pid
      init!(logs_flush_interval: 0) # no real TimerTask: no spurious flush in the test process
      old_buffer = CloseYourIt.send(:log_buffer)
      allow(old_buffer).to receive(:shutdown) # spy: shutdown would flush parent events

      allow(Process).to receive(:pid).and_return(real_pid + 1)

      new_buffer = CloseYourIt.send(:log_buffer)

      expect(new_buffer).not_to equal(old_buffer)
      expect(old_buffer).not_to have_received(:shutdown)
    end
  end

  describe "CloseYourIt.after_fork (explicit hook for worker hooks)" do
    it "abandons the inherited client and buffer and recreates them, without draining them" do
      init!(logs_flush_interval: 0)
      old_client = CloseYourIt.send(:client)
      old_buffer = CloseYourIt.send(:log_buffer)
      allow(old_client).to receive(:shutdown)
      allow(old_buffer).to receive(:shutdown)

      CloseYourIt.after_fork

      expect(old_client).not_to have_received(:shutdown)
      expect(old_buffer).not_to have_received(:shutdown)
      expect(CloseYourIt.send(:client)).not_to equal(old_client)
      expect(CloseYourIt.send(:log_buffer)).not_to equal(old_buffer)
    end

    it "is a safe no-op when client/buffer were never materialized" do
      init!
      expect(CloseYourIt.instance_variable_get(:@client)).to be_nil

      expect { CloseYourIt.after_fork }.not_to raise_error
      expect(CloseYourIt.instance_variable_get(:@client)).to be_nil
    end
  end

  describe "Ticket scenario 1 — real fork (Process.fork)" do
    it "the child creates its own resources and delivers the event; no event is left to the parent" do
      skip "Process.fork not available on this platform" unless Process.respond_to?(:fork)

      init!(async_threads: 1) # real thread pool: the case where fork breaks telemetry
      parent_client = CloseYourIt.send(:client)
      # Starts (and then leaves idle) a worker thread in the parent: so the pool state inherited by the
      # child has a "ready" worker that does not exist in the child — the condition that left the event
      # to the parent.
      warmup = Thread::Queue.new
      parent_client.instance_variable_get(:@worker).perform { warmup << :done }
      warmup.pop

      reader, writer = IO.pipe

      pid = Process.fork do
        reader.close
        result = {}
        begin
          # Does NOT call after_fork: checks lazy PID change detection on the first event.
          child_client = CloseYourIt.send(:client)
          delivered = Thread::Queue.new
          fake_transport = Object.new
          fake_transport.define_singleton_method(:send_event) { |_payload, path:| delivered << path }
          child_client.instance_variable_set(:@transport, fake_transport)

          result[:new_client] = !child_client.equal?(parent_client)
          result[:running] = child_client.instance_variable_get(:@worker).executor.running?

          CloseYourIt.capture_message("child-evt")
          CloseYourIt.shutdown # drains the child worker: waits for the in-flight send
          result[:delivered] = !delivered.empty?
        rescue StandardError => e
          result[:error] = "#{e.class}: #{e.message}"
        ensure
          writer.write(JSON.generate(result))
          writer.close
          exit!(0)
        end
      end

      writer.close
      raw = +""
      begin
        Timeout.timeout(20) do
          raw = reader.read
          Process.wait(pid)
        end
      rescue Timeout::Error
        Process.kill("KILL", pid)
        Process.wait(pid)
        raise "the child process did not answer within the timeout"
      ensure
        reader.close
      end

      result = JSON.parse(raw)
      expect(result["error"]).to be_nil
      # The child created its own resources (it did not reuse the client inherited from the parent)…
      expect(result["new_client"]).to be(true)
      expect(result["running"]).to be(true)
      # …and delivered the event through its OWN worker (no event left to the parent).
      expect(result["delivered"]).to be(true)
    end
  end
end
