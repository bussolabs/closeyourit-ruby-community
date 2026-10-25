# frozen_string_literal: true

RSpec.describe CloseYourIt::Performance::Rollup do
  let(:config) do
    CloseYourIt::Configuration.new.tap do |c|
      c.detect_performance_issues = true
      c.n_plus_one_threshold = 5
      c.query_count_threshold = 100
      c.query_time_threshold_ms = 1_000_000   # effectively disables the time gate in tests
      c.slow_request_threshold_ms = 1000
      c.slow_external_threshold_ms = 1000
    end
  end

  def profile
    CloseYourIt::Performance::RequestProfile.new
  end

  def rollup(prof, route: "OrdersController#index", request_duration_ms: 10)
    described_class.call(profile: prof, configuration: config, route: route,
                         request_duration_ms: request_duration_ms, trace_id: "req-1")
  end

  it "emits an n_plus_one verdict when a group exceeds the threshold" do
    prof = profile
    6.times { prof.add_query(fingerprint: "SELECT * FROM items WHERE order_id = <n>", source: "app/models/order.rb:42", duration_ms: 3) }
    events = rollup(prof)
    n1 = events.map(&:to_h).find { |h| h["subtype"] == "n_plus_one" }
    expect(n1).not_to be_nil
    expect(n1["query_count"]).to eq(6)
    expect(n1["trace_id"]).to eq("req-1")
    expect(n1["source"]).to eq("app/models/order.rb:42")
  end

  it "does NOT emit n_plus_one at the threshold (count = threshold)" do
    prof = profile
    5.times { prof.add_query(fingerprint: "SELECT 1", source: "a.rb:1", duration_ms: 1) }
    subtypes = rollup(prof).map { |e| e.to_h["subtype"] }
    expect(subtypes).not_to include("n_plus_one")
  end

  it "emits slow_request when the duration exceeds the threshold" do
    events = rollup(profile.tap { |p| p.add_query(fingerprint: "SELECT 1", source: "a.rb:1", duration_ms: 1) },
                    request_duration_ms: 1500)
    sr = events.map(&:to_h).find { |h| h["subtype"] == "slow_request" }
    expect(sr).not_to be_nil
    expect(sr["route"]).to eq("OrdersController#index")
    expect(sr["duration_ms"]).to eq(1500.0)
  end

  it "emits high_query_count when total queries exceed the threshold" do
    prof = profile
    101.times { |i| prof.add_query(fingerprint: "Q#{i}", source: "s#{i}", duration_ms: 1) }
    hqc = rollup(prof).map(&:to_h).find { |h| h["subtype"] == "high_query_count" }
    expect(hqc).not_to be_nil
    expect(hqc["query_count"]).to eq(101)
  end

  it "emits slow_external_http for an external call over the threshold" do
    prof = profile
    prof.add_external(host: "api.stripe.com", path: "/v1/charges/<id>", duration_ms: 1200)
    prof.add_external(host: "fast.example.com", path: "/ok", duration_ms: 50)
    ext = rollup(prof).map(&:to_h).select { |h| h["subtype"] == "slow_external_http" }
    expect(ext.size).to eq(1)
    expect(ext.first["http_host"]).to eq("api.stripe.com")
  end

  it "emits no verdict for an empty profile + fast request" do
    expect(rollup(profile, request_duration_ms: 10)).to be_empty
  end
end
