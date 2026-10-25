# frozen_string_literal: true

RSpec.describe CloseYourIt::Performance::RequestProfile do
  subject(:profile) { described_class.new }

  it "starts empty" do
    expect(profile).to be_empty
    expect(profile.query_count).to eq(0)
    expect(profile.total_query_time_ms).to eq(0.0)
  end

  it "accumulates query count and total time" do
    profile.add_query(fingerprint: "SELECT * FROM t WHERE id = <n>", source: "a.rb:1", duration_ms: 5)
    profile.add_query(fingerprint: "SELECT * FROM t WHERE id = <n>", source: "a.rb:1", duration_ms: 7)
    expect(profile.query_count).to eq(2)
    expect(profile.total_query_time_ms).to eq(12.0)
    expect(profile).not_to be_empty
  end

  it "groups by [fingerprint, source]: same template + same origin = one growing group" do
    3.times { profile.add_query(fingerprint: "SELECT 1", source: "a.rb:1", duration_ms: 2) }
    profile.add_query(fingerprint: "SELECT 1", source: "b.rb:2", duration_ms: 2)
    groups = profile.query_groups.values
    counts = groups.map { |g| g[:count] }.sort
    expect(counts).to eq([ 1, 3 ])
  end

  it "excludes cached queries (not a DB round-trip → not N+1)" do
    profile.add_query(fingerprint: "SELECT 1", source: "a.rb:1", duration_ms: 2, cached: true)
    expect(profile.query_count).to eq(0)
    expect(profile).to be_empty
  end

  it "accumulates external HTTP calls" do
    profile.add_external(host: "api.stripe.com", path: "/v1/charges/<id>", duration_ms: 900)
    expect(profile.external_calls.size).to eq(1)
    expect(profile.external_calls.first[:host]).to eq("api.stripe.com")
    expect(profile).not_to be_empty
  end

  it "caps the distinct groups tracked (memory guard)" do
    (described_class::MAX_GROUPS + 50).times do |i|
      profile.add_query(fingerprint: "Q#{i}", source: "s#{i}", duration_ms: 1)
    end
    expect(profile.query_groups.size).to be <= described_class::MAX_GROUPS
    # but the total count keeps growing
    expect(profile.query_count).to eq(described_class::MAX_GROUPS + 50)
  end
end
