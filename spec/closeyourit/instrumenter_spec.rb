# frozen_string_literal: true

RSpec.describe "CloseYourIt.measure" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/metrics" }

  def enable!(threshold:)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_method_threshold_ms = threshold
    end
  end

  it "returns the block value" do
    enable!(threshold: 1_000_000)
    expect(CloseYourIt.measure("x") { 42 }).to eq(42)
  end

  it "sends slow_method on the /metrics path when over the threshold (no args)" do
    enable!(threshold: 0)
    stub = stub_request(:post, url)

    CloseYourIt.measure("checkout.total") { :done }

    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["kind"] == "slow_method" &&
        body["label"] == "checkout.total" &&
        body["sample_id"].is_a?(String) &&
        body.key?("duration_ms") &&
        !body.key?("arguments")
    }
  end

  it "does not send when under the threshold" do
    enable!(threshold: 1_000_000)
    stub = stub_request(:post, url)
    CloseYourIt.measure("fast") { 1 }
    expect(stub).not_to have_been_requested
  end

  it "re-raises the block exception" do
    enable!(threshold: 1_000_000)
    expect { CloseYourIt.measure("x") { raise "boom" } }.to raise_error("boom")
  end
end

RSpec.describe CloseYourIt::Monitor do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/metrics" }

  it "wraps the method keeping the return value and sends slow_method" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_method_threshold_ms = 0
    end
    stub_request(:post, url)

    klass = Class.new do
      include CloseYourIt::Monitor
      def compute(first, second) = first + second
      monitor :compute
    end

    expect(klass.new.compute(3, 4)).to eq(7)
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["kind"] == "slow_method" && body["label"].include?("compute") && !body.key?("arguments")
    }
  end

  it "keeps the block passed to the method and does not send under the threshold" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_method_threshold_ms = 1_000_000
    end
    stub = stub_request(:post, url)

    klass = Class.new do
      include CloseYourIt::Monitor
      def each_double(values, &block) = values.map(&block)
      monitor :each_double
    end

    expect(klass.new.each_double([ 1, 2 ]) { |n| n * 2 }).to eq([ 2, 4 ])
    expect(stub).not_to have_been_requested
  end

  it "includes arguments (positional + scrubbed kwargs) when capture_method_arguments is ON" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_method_threshold_ms = 0
      c.capture_method_arguments = true
    end
    stub_request(:post, url)

    klass = Class.new do
      include CloseYourIt::Monitor
      def run(period, password:) = [ period, password ]
      monitor :run
    end

    klass.new.run("daily", password: "secret")

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body)["arguments"] == [
        { "name" => "arg1", "value" => "\"daily\"" },
        { "name" => "password", "value" => "[FILTERED]" }
      ]
    }
  end
end

# CYRB-24 R3 — Instrumenter#measure computed and sent inside an `ensure` without rescue, on the
# Monitor#monitor path (prepended to the app's methods): with a nil threshold the comparison raised
# ArgumentError INSIDE the host method, which had already produced its result.
RSpec.describe "CloseYourIt.measure — never raises in the host app (CYRB-24)" do
  def init_with(threshold)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_method_threshold_ms = threshold
    end
  end

  it "returns the block value even with a nil threshold" do
    init_with(nil)
    allow(CloseYourIt.internal_logger).to receive(:error)

    expect(CloseYourIt.measure("missing-threshold") { 42 }).to eq(42)
  end

  it "logs the internal failure instead of propagating it" do
    init_with(nil)
    allow(CloseYourIt.internal_logger).to receive(:error)

    CloseYourIt.measure("missing-threshold") { 42 }

    expect(CloseYourIt.internal_logger).to have_received(:error).with(/instrumenter/i)
  end

  it "does not alter the original exception of the measured block" do
    init_with(nil)
    allow(CloseYourIt.internal_logger).to receive(:error)

    expect { CloseYourIt.measure("missing-threshold") { raise "app error" } }
      .to raise_error("app error")
  end

  it "returns the monitored method result with a nil threshold" do
    init_with(nil)
    allow(CloseYourIt.internal_logger).to receive(:error)

    klass = Class.new do
      include CloseYourIt::Monitor
      def sum(first, second) = first + second
      monitor :sum
    end

    expect(klass.new.sum(40, 2)).to eq(42)
  end

  it "does not propagate even when sending the event fails" do
    init_with(0)
    allow(CloseYourIt.internal_logger).to receive(:error)
    allow(CloseYourIt).to receive(:capture_event).and_raise("ingest unreachable")

    expect(CloseYourIt.measure("broken-send") { 42 }).to eq(42)
  end
end
