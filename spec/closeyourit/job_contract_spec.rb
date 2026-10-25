# frozen_string_literal: true

require "json_schemer"
require "digest"

RSpec.describe "Pinned job contract" do
  let(:root) { File.expand_path("../../contracts/jobs/v1", __dir__) }
  let(:schema) { JSON.parse(File.read(File.join(root, "schema.json"))) }
  let(:validator) do
    JSONSchemer.schema({ "$ref" => "#/$defs/job_context", "$defs" => schema.fetch("$defs") }, format: true, regexp_resolver: "ecma")
  end

  it "keeps every vendored file pinned to the canonical commit" do
    lock = JSON.parse(File.read(File.join(root, "LOCK.json")))
    lock.fetch("sha256").each do |path, digest|
      expect(Digest::SHA256.file(File.join(root, path)).hexdigest).to eq(digest)
    end
  end

  it "emits a closed valid context for known, missing and skewed clocks" do
    [ [ 100, 700, 730 ], [ nil, 700, 730 ], [ 100, nil, 90 ] ].each do |enqueue, schedule, start|
      context = CloseYourIt::JobContext.build(framework: "sidekiq", name: "ReportJob",
        enqueued_at: enqueue, scheduled_at: schedule, started_at: start, retry_count: nil, attempt: 1)
      expect(validator.validate(context).to_a).to be_empty
    end
  end

  it "bounds untrusted descriptive metadata without reading arguments" do
    context = CloseYourIt::JobContext.build(framework: "sidekiq", name: "x" * 201,
      queue: "queue\nname", job_id: "x" * 257)
    expect(context).to include("name" => "unknown", "queue" => nil, "job_id" => nil)
    expect(validator.valid?(context)).to be(true)
  end
end
