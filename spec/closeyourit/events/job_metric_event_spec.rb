# frozen_string_literal: true

RSpec.describe CloseYourIt::JobMetricEvent do
  let(:config) do
    CloseYourIt::Configuration.new.tap do |c|
      c.environment = "production"
      c.release = "v1.2.3"
    end
  end

  def event(attrs = {})
    described_class.new(
      { subtype: "slow_job", duration_ms: 8123.456, job_class: "MailDeliveryJob",
        queue: "mailers", adapter: "active_job", attempt: 2, trace_id: "job-9" }.merge(attrs),
      config
    )
  end

  it "builds the kind=performance_issue payload with the job fields" do
    h = event.to_h
    expect(h["kind"]).to eq("performance_issue")
    expect(h["subtype"]).to eq("slow_job")
    expect(h["duration_ms"]).to eq(8123.46)
    expect(h["label"]).to eq("MailDeliveryJob")
    expect(h["queue"]).to eq("mailers")
    expect(h["adapter"]).to eq("active_job")
    expect(h["attempt"]).to eq(2)
    expect(h["trace_id"]).to eq("job-9")
    expect(h["release"]).to eq("v1.2.3")
    expect(h["environment"]).to eq("production")
    expect(h["sample_id"]).to be_a(String)
    expect(h["sdk"]).to eq("name" => "closeyourit-ruby", "version" => CloseYourIt::VERSION)
  end

  it "never sends the job arguments (only the label = class name)" do
    expect(event.to_h.keys).not_to include("arguments", "args", "kwargs")
  end

  it "sends to the /metrics path" do
    expect(event.ingest_path("proj-1")).to eq("/api/v1/projects/proj-1/metrics")
  end

  it "omits nil fields (missing queue/attempt/release)" do
    # `config.release = nil` is NOT enough: the reader auto-detects (tag, deploy ENV, `git rev-parse`).
    # `git_revision` excludes itself when `.git` is not a directory — true in a git worktree, where
    # `.git` is a file, FALSE in a normal checkout like the one from `actions/checkout`. The spec passed
    # only when run from a worktree and failed in CI, where `detect_release` returned the short SHA.
    # What matters here is the absence of the release, not how it is detected: the reader is stubbed.
    allow(config).to receive(:release).and_return(nil)
    h = event(queue: nil, attempt: nil).to_h
    expect(h).not_to have_key("queue")
    expect(h).not_to have_key("attempt")
    expect(h).not_to have_key("release")
  end
end
