# frozen_string_literal: true

RSpec.describe CloseYourIt::LogEvent do
  def config
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.environment = "production"
      c.release = "v1.2"
    end
    CloseYourIt.configuration
  end

  after { CloseYourIt.clear_scope }

  it "produces the log payload with all fields" do
    event = described_class.new("hello", level: :warning, attributes: { user_id: 9 },
                                logger: "system", configuration: config)
    payload = event.to_h
    expect(payload["level"]).to eq("warning")
    expect(payload["message"]).to eq("hello")
    expect(payload["attributes"]).to eq("user_id" => 9)
    expect(payload["logger"]).to eq("system")
    expect(payload["environment"]).to eq("production")
    expect(payload["release"]).to eq("v1.2")
    expect(payload["event_id"]).to be_a(String)
    expect(payload["sdk"]["name"]).to eq("closeyourit-ruby")
  end

  it "normalizes the level to the backend canonical values (even when built directly)" do
    expect(described_class.new("x", level: :warn, attributes: {}, configuration: config).to_h["level"]).to eq("warning")
    expect(described_class.new("x", level: "ERROR", attributes: {}, configuration: config).to_h["level"]).to eq("error")
    expect(described_class.new("x", level: :verbose, attributes: {}, configuration: config).to_h["level"]).to eq("info")
  end

  it "normalizes the err/unknown aliases" do
    expect(described_class.new("x", level: :err, attributes: {}, configuration: config).to_h["level"]).to eq("error")
    expect(described_class.new("x", level: :unknown, attributes: {}, configuration: config).to_h["level"]).to eq("fatal")
  end

  describe ".normalize_level (single source, exposed as a class method)" do
    it "returns the normalized canonical level" do
      expect(described_class.normalize_level(:warn)).to eq("warning")
      expect(described_class.normalize_level("ERROR")).to eq("error")
    end

    it "falls back to info for an unknown level" do
      expect(described_class.normalize_level(:verbose)).to eq("info")
      expect(described_class.normalize_level(nil)).to eq("info")
    end
  end

  describe ".severity (numeric level map, identical across SDKs)" do
    it "maps the canonical levels to the cross-SDK indexes (debug=0 … fatal=4)" do
      expect(described_class.severity(:debug)).to eq(0)
      expect(described_class.severity(:info)).to eq(1)
      expect(described_class.severity(:warning)).to eq(2)
      expect(described_class.severity(:error)).to eq(3)
      expect(described_class.severity(:fatal)).to eq(4)
    end

    it "normalizes aliases before computing the severity (warn→2, err→3, unknown→4)" do
      expect(described_class.severity(:warn)).to eq(2)
      expect(described_class.severity(:err)).to eq(3)
      expect(described_class.severity(:unknown)).to eq(4)
    end

    it "falls back to the info severity (1) for an unknown level" do
      expect(described_class.severity(:verbose)).to eq(1)
      expect(described_class.severity(nil)).to eq(1)
    end
  end

  it "scrubs sensitive keys inside nested arrays in attributes" do
    event = described_class.new("x", level: :info,
                                attributes: { items: [ { token: "t", ok: "v" } ] }, configuration: config)
    expect(event.to_h["attributes"]["items"]).to eq([ { "token" => "[FILTERED]", "ok" => "v" } ])
  end

  it "points ingest_path to /logs" do
    event = described_class.new("x", level: :info, attributes: {}, configuration: config)
    expect(event.ingest_path("p1")).to eq("/api/v1/projects/p1/logs")
  end

  it "scrubs sensitive attributes (recursively)" do
    event = described_class.new("x", level: :info,
                                attributes: { password: "hunter2", nested: { token: "k", ok: "v" } },
                                configuration: config)
    data = event.to_h["attributes"]
    expect(data["password"]).to eq("[FILTERED]")
    expect(data["nested"]).to eq("token" => "[FILTERED]", "ok" => "v")
  end

  it "includes the trace_id from the current scope (correlation)" do
    config
    CloseYourIt::Scope.current.trace_id = "trace-1"
    event = described_class.new("x", level: :info, attributes: {}, configuration: CloseYourIt.configuration)
    expect(event.to_h["trace_id"]).to eq("trace-1")
  end

  it "omits trace_id and logger when absent (compact)" do
    payload = described_class.new("x", level: :info, attributes: {}, configuration: config).to_h
    expect(payload).not_to have_key("trace_id")
    expect(payload).not_to have_key("logger")
  end

  it "scrubs the message with the configured scrub_message_patterns (PII like exception.message)" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.scrub_message_patterns = [ /hunter2/ ]
    end
    event = described_class.new("login with password hunter2", level: :info, attributes: {},
                                configuration: CloseYourIt.configuration)
    expect(event.to_h["message"]).to eq("login with password [FILTERED]")
  end

  it "freezes the trace_id at construction: a later scope change (cross-thread flush) does not alter it" do
    config
    CloseYourIt::Scope.current.trace_id = "trace-construction"
    event = described_class.new("x", level: :info, attributes: {}, configuration: CloseYourIt.configuration)
    CloseYourIt::Scope.current.trace_id = "trace-other-request" # simulates the timer thread with another scope
    expect(event.to_h["trace_id"]).to eq("trace-construction")
  end
end
