# frozen_string_literal: true

require "closeyourit/job_context"

RSpec.describe CloseYourIt::JobContext do
  it "uses explicit Sidekiq versions to distinguish milliseconds from legacy seconds" do
    epoch = 1_791_120_000.125
    expect(described_class.sidekiq_time(epoch, version: "7.3.9")).to eq(epoch)
    expect(described_class.sidekiq_time((epoch * 1000).to_i, version: "8.1.7")).to eq(epoch)
    expect(described_class.sidekiq_time(epoch, version: nil)).to eq(epoch)
    expect(described_class.sidekiq_time(nil, version: "8.1.7")).to be_nil
  end

  it "separates planned delay, queue wait and unknown enqueue" do
    context = described_class.build(framework: "active_job", name: "ReportJob", enqueued_at: Time.at(100),
      scheduled_at: Time.at(700), started_at: Time.at(730), attempt: 2)
    expect(context).to include("queue_wait_ms" => 30_000.0, "scheduled_delay_ms" => 600_000.0,
      "attempt" => 2, "retry_count" => 1, "terminal" => nil, "attempt_outcome" => "unknown")
    missing = described_class.build(framework: "active_job", name: "ReportJob", scheduled_at: Time.at(700), started_at: Time.at(730))
    expect(missing).to include("queue_wait_ms" => nil, "scheduled_delay_ms" => nil)
  end

  it "keeps clock skew visible without negative duration" do
    context = described_class.build(framework: "active_job", name: "ReportJob", enqueued_at: Time.at(100), started_at: Time.at(90))
    expect(context).to include("queue_wait_ms" => 0.0, "clock_skew" => true)
  end

  it "does not infer a timezone or accept nonfinite times" do
    [ "2026-10-04T12:00:00", "2026-02-31T00:00:00Z", Float::INFINITY, Float::NAN ].each do |value|
      context = described_class.build(framework: "active_job", name: "ReportJob", enqueued_at: value, started_at: Time.at(100))
      expect(context["queue_wait_ms"]).to be_nil
    end
  end
end
