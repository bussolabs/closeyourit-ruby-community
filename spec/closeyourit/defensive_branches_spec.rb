# frozen_string_literal: true

require "spec_helper"

# Exercises the defensive branches (no-op guards, nil/edge input handling, transport error paths)
# left uncovered by branch coverage. They are real behaviors the gem promises — "no-op when
# disabled", "never raise into the app" — and the branch 90 gate locks them in (CYRB-13).
RSpec.describe "defensive branches" do
  describe "module API without credentials (no-op)" do
    it "init without a block stays configured and does not raise" do
      expect { CloseYourIt.init }.not_to raise_error
      expect(CloseYourIt.configured?).to be(true)
      expect(CloseYourIt.enabled?).to be(false)
    end

    it "capture_event is a no-op when the client is disabled" do
      expect(CloseYourIt.capture_event(Object.new)).to be_nil
    end

    it "capture_message is a no-op when the client is disabled" do
      expect(CloseYourIt.capture_message("hello")).to be_nil
    end

    it "configure_scope without a block does not raise" do
      expect { CloseYourIt.configure_scope }.not_to raise_error
    end

    it "suppresses telemetry while the diagnostic hook is running" do
      Thread.current[CloseYourIt::DIAGNOSTIC_GUARD] = true
      expect(CloseYourIt.capture_exception(RuntimeError.new("x"))).to be_nil
      expect(CloseYourIt.capture_event(Object.new)).to be_nil
      expect(CloseYourIt.emit_log(:info, "x")).to be_nil
    ensure
      Thread.current[CloseYourIt::DIAGNOSTIC_GUARD] = false
    end
  end

  describe "configuration validation" do
    it "warns when project_id is not shaped like a UUID" do
      expect(CloseYourIt.internal_logger).to receive(:warn).with(/UUID/)
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "not-a-uuid"
      end
    end
  end

  describe "guards on nil/synthetic input" do
    it "LineCache.lines returns nil for missing or synthetic paths" do
      expect(CloseYourIt::LineCache.lines(nil)).to be_nil
      expect(CloseYourIt::LineCache.lines("")).to be_nil
      expect(CloseYourIt::LineCache.lines("(eval)")).to be_nil
    end

    it "Scrubber.scrub_message lets nil through" do
      scrubber = CloseYourIt::Scrubber.new(CloseYourIt.configuration)
      expect(scrubber.scrub_message(nil)).to be_nil
    end
  end

  describe "Client#flush_logs" do
    let(:config) do
      CloseYourIt.configuration.tap { |c| c.async_threads = 0 }
    end

    it "is a no-op with an empty or nil batch" do
      client = CloseYourIt::Client.new(config)
      expect(client.flush_logs([])).to be_nil
      expect(client.flush_logs(nil)).to be_nil
    ensure
      client&.shutdown
    end

    it "sends nothing when before_send drops every log" do
      config.before_send = ->(_payload) { nil }
      client = CloseYourIt::Client.new(config)
      log = CloseYourIt::LogEvent.new("msg", level: :info, attributes: {}, configuration: config)
      expect(client.flush_logs([ log ])).to be_nil
      expect(CloseYourIt.stats.to_h[:dropped]).to be >= 1
    ensure
      client&.shutdown
    end
  end

  describe "event building" do
    it "omits server_name when send_server_name is disabled" do
      config = CloseYourIt.configuration.tap { |c| c.send_server_name = false }
      event = CloseYourIt::MessageEvent.new("hello", level: "info", configuration: config)
      expect(event.to_h["server_name"]).to be_nil
    end

    it "uses the string value of binds without #name" do
      config = CloseYourIt.configuration.tap { |c| c.capture_query_bindings = true }
      event = CloseYourIt::SlowQueryEvent.new(
        { name: "User Load", sql: "SELECT 1", binds: [ "col" ], type_casted_binds: [ "v" ] },
        120.0, config
      )
      expect(event.send(:bindings)).to eq([ { "name" => "col", "value" => "v" } ])
    end

    it "truncates method arguments that are too long" do
      config = CloseYourIt.configuration.tap { |c| c.capture_method_arguments = true }
      event = CloseYourIt::SlowMethodEvent.new("label", 250.0, nil, config, args: [ "x" * 200 ])
      value = event.send(:safe_value, "x" * 200)
      expect(value).to end_with("…")
      expect(value.length).to eq(118)
    end
  end

  describe "ErrorEvent#relative_filename e #in_app? (path edge)" do
    def build_event(config)
      exception = begin
        raise "boom"
      rescue StandardError => e
        e
      end
      CloseYourIt::ErrorEvent.from_exception(exception, configuration: config)
    end

    it "lets a nil path through and excludes it from the app" do
      event = build_event(CloseYourIt.configuration)
      expect(event.send(:relative_filename, nil)).to be_nil
      expect(event.send(:in_app?, nil)).to be(false)
    end

    it "uses the basename when project_root is empty" do
      config = CloseYourIt.configuration.tap { |c| c.project_root = "" }
      event = build_event(config)
      expect(event.send(:relative_filename, "/any/path/file.rb")).to eq("file.rb")
    end

    it "uses the basename when the path equals project_root" do
      config = CloseYourIt.configuration.tap { |c| c.project_root = "/app" }
      event = build_event(config)
      expect(event.send(:relative_filename, "/app/")).to eq("app")
    end
  end

  describe "Subscribers::SlowQuery" do
    let(:config) { CloseYourIt.configuration }
    let(:subscriber) { CloseYourIt::Subscribers::SlowQuery.new(config) }

    it "adds no breadcrumb when breadcrumbs are disabled" do
      config.breadcrumbs_enabled = false
      expect do
        subscriber.breadcrumb(name: "User Load", sql: "SELECT 1", duration_ms: 5)
      end.not_to(change { CloseYourIt::Scope.current.breadcrumbs.size })
    end

    it "does not profile queries when detection is disabled" do
      config.detect_performance_issues = false
      expect(subscriber.profile(name: "User Load", sql: "SELECT 1", duration_ms: 5)).to be_nil
    end

    it "skips system queries even with detection enabled" do
      config.detect_performance_issues = true
      expect(subscriber.profile(name: "SCHEMA", sql: "SET x", duration_ms: 5)).to be_nil
    end
  end

  describe "Transport: error paths (client enabled)" do
    let(:events_url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

    def configure_enabled!
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.async_threads = 0 # synchronous send, deterministic for WebMock
      end
    end

    def sample_exception
      raise "boom"
    rescue StandardError => e
      e
    end

    before do
      configure_enabled!
      allow(CloseYourIt.internal_logger).to receive(:warn)
      allow(CloseYourIt.internal_logger).to receive(:error)
    end

    it "does not send its own internal exceptions (CloseYourIt::Error)" do
      stub = stub_request(:post, events_url)
      CloseYourIt.capture_exception(CloseYourIt::Error.new("internal"))
      expect(stub).not_to have_been_requested
    end

    it "classifies a non-timeout network error as a network drop" do
      stub_request(:post, events_url).to_raise(SocketError.new("getaddrinfo"))
      expect { CloseYourIt.capture_exception(sample_exception) }.not_to raise_error
      expect(CloseYourIt.stats.to_h[:failed]).to be >= 1
    end

    it "ignores a malformed error envelope (non-Hash error)" do
      stub_request(:post, events_url).to_return(status: 400, body: '{"error":"string"}')
      expect { CloseYourIt.capture_exception(sample_exception) }.not_to raise_error
    end

    it "handles an error envelope without code/message" do
      stub_request(:post, events_url).to_return(status: 400, body: '{"error":{}}')
      expect { CloseYourIt.capture_exception(sample_exception) }.not_to raise_error
    end
  end
end
