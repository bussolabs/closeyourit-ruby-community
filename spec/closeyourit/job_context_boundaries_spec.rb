# frozen_string_literal: true

RSpec.describe "Job context input boundaries" do
  it "does not turn invalid schedule, counters or time into known values" do
    context = CloseYourIt::JobContext.build(framework: "sidekiq", name: "Worker", attempt: 0,
      retry_count: -1, enqueued_at: "not-a-time", scheduled_at: "2026-10-04T12:00:00Z", started_at: Time.now.utc)
    expect(context).to include("attempt" => nil, "retry_count" => nil, "queue_wait_ms" => nil)
    fallback = CloseYourIt::JobContext.build(framework: "active_job", name: "Worker", attempt: 1,
      enqueued_at: Time.at(100), scheduled_at: "invalid", started_at: Time.at(101))
    expect(fallback).to include("queue_wait_ms" => 1000.0, "scheduled_delay_ms" => nil)
    expect(CloseYourIt::JobContext.sidekiq_time(1_000, version: "8.0.0")).to eq(1.0)
  end
end
