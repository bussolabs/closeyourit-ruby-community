# frozen_string_literal: true

RSpec.describe CloseYourIt::Subscribers::RequestPerformance do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/metrics" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.detect_performance_issues = true
      c.n_plus_one_threshold = 5
      over.each { |k, v| c.public_send("#{k}=", v) }
    end
  end

  before { CloseYourIt::Scope.reset! }
  after { CloseYourIt::Scope.reset! }

  def fill_profile(count:, source: "app/models/order.rb:42", duration_ms: 3)
    profile = CloseYourIt::Scope.current.performance_profile
    count.times { profile.add_query(fingerprint: "SELECT * FROM items WHERE order_id = <n>", source: source, duration_ms: duration_ms) }
    CloseYourIt::Scope.current.trace_id = "req-xyz"
  end

  it "emits an n_plus_one verdict with trace_id on the /metrics path" do
    enable!
    stub = stub_request(:post, url)
    fill_profile(count: 6)

    described_class.new.record(route: "OrdersController#index", duration_ms: 20)

    expect(stub).to have_been_requested.at_least_once
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["kind"] == "performance_issue" && body["subtype"] == "n_plus_one" &&
        body["trace_id"] == "req-xyz" && body["query_count"] == 6
    }
  end

  it "emits nothing when detect_performance_issues is OFF" do
    enable!(detect_performance_issues: false)
    stub = stub_request(:post, url)
    fill_profile(count: 6)

    described_class.new.record(route: "OrdersController#index", duration_ms: 20)

    expect(stub).not_to have_been_requested
  end

  it "emits nothing with an empty profile and a fast request" do
    enable!
    stub = stub_request(:post, url)

    described_class.new.record(route: "OrdersController#index", duration_ms: 10)

    expect(stub).not_to have_been_requested
  end

  # The body of the Railtie's process_action.action_controller listener (CYRB-35).
  describe "#process_action" do
    let(:payload) { { controller: "OrdersController", action: "index" } }

    it "records the route usage and emits the performance verdicts" do
      enable!
      stub = stub_request(:post, url)
      allow(CloseYourIt.usage_registry).to receive(:record)
      fill_profile(count: 6)

      described_class.new.process_action(payload, 20)

      expect(CloseYourIt.usage_registry).to have_received(:record).with("route", "OrdersController#index")
      expect(stub).to have_been_requested.at_least_once
    end

    it "does not touch the usage registry when the gem is disabled" do
      CloseYourIt.init { |c| c.project_id = nil }
      expect(CloseYourIt).not_to receive(:usage_registry)

      expect(described_class.new.process_action(payload, 20)).to be_nil
    end

    context "when the end-of-request work fails" do
      let(:logger) { instance_double(Logger, warn: nil) }

      before do
        enable!
        CloseYourIt.internal_logger = logger
      end

      after { CloseYourIt.internal_logger = nil }

      it "absorbs a usage registry fault and logs it, without raising into the request" do
        allow(CloseYourIt.usage_registry).to receive(:record).and_raise(NoMethodError, "registry bug")

        expect { described_class.new.process_action(payload, 20) }.not_to raise_error

        expect(logger).to have_received(:warn).with(/request observation failed: NoMethodError: registry bug/)
      end

      it "absorbs a performance rollup fault and logs it, without raising into the request" do
        allow(CloseYourIt.usage_registry).to receive(:record)
        allow(CloseYourIt::Performance::Rollup).to receive(:call).and_raise(ArgumentError, "rollup bug")
        fill_profile(count: 6)

        expect { described_class.new.process_action(payload, 20) }.not_to raise_error

        expect(logger).to have_received(:warn).with(/ArgumentError: rollup bug/)
      end
    end
  end
end
