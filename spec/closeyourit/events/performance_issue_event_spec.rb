# frozen_string_literal: true

RSpec.describe CloseYourIt::PerformanceIssueEvent do
  let(:config) { CloseYourIt::Configuration.new.tap { |c| c.environment = "production" } }

  def event(attrs = {})
    described_class.new(
      { subtype: "n_plus_one", duration_ms: 320.5, sql: "SELECT * FROM users WHERE id = <n>",
        source: "app/models/user.rb:10", query_count: 47, count_in_request: 47,
        total_query_time_ms: 300.0, trace_id: "req-9" }.merge(attrs),
      config
    )
  end

  it "builds the kind=performance_issue payload with the verdict fields" do
    h = event.to_h
    expect(h["kind"]).to eq("performance_issue")
    expect(h["subtype"]).to eq("n_plus_one")
    expect(h["duration_ms"]).to eq(320.5)
    expect(h["sql"]).to eq("SELECT * FROM users WHERE id = <n>")
    expect(h["source"]).to eq("app/models/user.rb:10")
    expect(h["query_count"]).to eq(47)
    expect(h["trace_id"]).to eq("req-9")
    expect(h["sample_id"]).to be_a(String)
    expect(h["environment"]).to eq("production")
  end

  it "sends to the /metrics path" do
    expect(event.ingest_path("proj-1")).to eq("/api/v1/projects/proj-1/metrics")
  end

  it "omits nil fields (slow_request has no sql/source)" do
    h = event(subtype: "slow_request", sql: nil, source: nil, route: "X#i", query_count: nil).to_h
    expect(h).not_to have_key("sql")
    expect(h).not_to have_key("source")
    expect(h["route"]).to eq("X#i")
  end
end
