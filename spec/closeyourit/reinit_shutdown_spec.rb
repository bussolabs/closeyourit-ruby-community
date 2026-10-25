# frozen_string_literal: true

# CYRB-10 — Re-init: close the previous client before replacing it. Before the fix `init` cleared
# @client and @log_buffer WITHOUT shutdown: the worker thread and the buffer TimerTask were orphaned,
# and events still queued were lost or flushed late by the orphan timer with the OLD credential. A new
# init must DRAIN and SHUT DOWN the previous client + log buffer — the same end-of-life semantics as
# CloseYourIt.shutdown (buffer flush → worker drain with timeout, CYRB-5) — before creating new ones.
RSpec.describe "CloseYourIt.init — closing the previous client on re-init (CYRB-10)" do
  after { CloseYourIt.clear_scope }

  # Synchronous init by default (async_threads: 0) and without timer (logs_flush_interval: 0): flush
  # happens only on a full batch or at shutdown, so the tests control when events leave. Async cases
  # override async_threads.
  def init!(endpoint: "https://closeyour.it", token: "tok", project_id: "proj-1", **over)
    CloseYourIt.init do |c|
      c.endpoint_url = endpoint
      c.token = token
      c.project_id = project_id
      c.async_threads = 0
      c.logs_batch_size = 50
      c.logs_flush_interval = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def logs_url(endpoint: "https://closeyour.it", project_id: "proj-1")
    "#{endpoint}/api/v1/projects/#{project_id}/logs"
  end

  describe "two consecutive inits" do
    it "shuts down the buffer and then the client of the previous configuration, in #shutdown order" do
      init!
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "x") # creates @log_buffer and @client of the first config

      old_buffer = CloseYourIt.instance_variable_get(:@log_buffer)
      old_client = CloseYourIt.instance_variable_get(:@client)
      order = []
      allow(old_buffer).to receive(:shutdown).and_wrap_original { |orig, *a| order << :buffer; orig.call(*a) }
      allow(old_client).to receive(:shutdown).and_wrap_original { |orig, *a| order << :client; orig.call(*a) }

      init! # second init

      expect(order).to eq(%i[buffer client])
    end

    it "replaces client and log buffer with new instances, not reusing those of the previous config" do
      init!
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "x")
      old_buffer = CloseYourIt.instance_variable_get(:@log_buffer)
      old_client = CloseYourIt.instance_variable_get(:@client)

      init!
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "y") # lazily recreates client + buffer under the new config

      expect(CloseYourIt.instance_variable_get(:@client)).not_to equal(old_client)
      expect(CloseYourIt.instance_variable_get(:@log_buffer)).not_to equal(old_buffer)
    end
  end

  describe "token/endpoint rotated between two inits" do
    it "flushes buffered events to the OLD endpoint with the OLD credential, never the new one" do
      init!(endpoint: "https://old.example", token: "old-tok", project_id: "proj-old")
      old_url = logs_url(endpoint: "https://old.example", project_id: "proj-old")
      new_url = logs_url(endpoint: "https://new.example", project_id: "proj-new")
      stub_request(:post, old_url)
      stub_request(:post, new_url)

      CloseYourIt.log(:info, "old") # buffered (< batch): not sent yet
      expect(WebMock).not_to have_requested(:post, old_url)

      init!(endpoint: "https://new.example", token: "new-tok", project_id: "proj-new")

      # The previous queue is drained to the OLD endpoint, with the OLD Bearer.
      expect(WebMock).to(have_requested(:post, old_url)
        .with(headers: { "Authorization" => "Bearer old-tok" }) do |req|
          body = JSON.parse(req.body)
          body.is_a?(Array) && body.first["message"] == "old"
        end)
      # No event of the old session ends up on the new endpoint / with the new credential.
      expect(WebMock).not_to have_requested(:post, new_url)
    end
  end

  describe "async worker of the previous configuration" do
    it "drains and waits for the previous worker's queued sends before replacing it (async_threads > 0)" do
      init!(async_threads: 2) # real thread pool
      stub_request(:post, logs_url)
      10.times { |i| CloseYourIt.log(:info, "log-#{i}") } # < batch → all queued in the buffer
      expect(WebMock).not_to have_requested(:post, logs_url)

      old_executor = CloseYourIt.instance_variable_get(:@client).instance_variable_get(:@worker).executor

      init!(async_threads: 2) # re-init: must drain the previous worker

      # Without the drain the async POST might not complete: here it is sent AND waited for.
      expect(WebMock).to(have_requested(:post, logs_url).with do |req|
        body = JSON.parse(req.body)
        body.is_a?(Array) && body.size == 10 && body.first["message"] == "log-0"
      end)
      # No orphan thread: the previous pool was shut down.
      expect(old_executor.shutdown?).to be(true)
    end
  end

  describe "Ticket scenario 1 — gem already initialized with queued logs and events" do
    it "closes the previous client: queue drained predictably, no orphan timer or thread" do
      init!(async_threads: 2, logs_flush_interval: 5) # periodic timer active + async worker
      stub_request(:post, logs_url)
      CloseYourIt.log(:info, "queued") # creates the buffer (starts the timer) and the worker; event queued

      old_buffer = CloseYourIt.instance_variable_get(:@log_buffer)
      old_client = CloseYourIt.instance_variable_get(:@client)
      old_timer = old_buffer.timer
      old_executor = old_client.instance_variable_get(:@worker).executor
      expect(old_timer.running?).to be(true) # timer started by the first entry
      allow(old_timer).to receive(:shutdown).and_call_original

      init!(async_threads: 2, token: "new") # new configuration

      # Queue drained predictably: the event is delivered during shutdown, not lost.
      expect(WebMock).to(have_requested(:post, logs_url).with do |req|
        JSON.parse(req.body).first["message"] == "queued"
      end)
      # No orphan timer (the previous buffer's TimerTask was stopped)…
      expect(old_timer).to have_received(:shutdown)
      # …nor orphan threads (the previous worker pool was shut down).
      expect(old_executor.shutdown?).to be(true)
    end
  end

  describe "client never created / no-op" do
    it "is a safe re-init when the previous init never instantiated client or buffer" do
      init! # no log/capture: @client and @log_buffer stay nil
      expect(CloseYourIt.instance_variable_get(:@client)).to be_nil
      expect(CloseYourIt.instance_variable_get(:@log_buffer)).to be_nil

      expect { init! }.not_to raise_error
    end

    it "does not raise on re-init when the previous configuration was disabled (no-op)" do
      init!(token: nil) # disabled: enabled? false → capture/log are no-ops
      CloseYourIt.log(:info, "dropped")
      CloseYourIt.capture_message("dropped")
      expect(CloseYourIt.instance_variable_get(:@log_buffer)).to be_nil

      expect { init! }.not_to raise_error
    end
  end
end
