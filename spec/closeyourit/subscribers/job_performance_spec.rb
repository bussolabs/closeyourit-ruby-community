# frozen_string_literal: true

RSpec.describe CloseYourIt::Subscribers::JobPerformance do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/metrics" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  # Fake job (no ActiveJob): responds like a real ActiveJob::Base.
  class DummyPerfJob
    attr_reader :job_id, :executions, :queue_name, :enqueued_at

    def initialize(enqueued_at: nil, executions: 1)
      @job_id = "j-1"
      @executions = executions
      @queue_name = "mailers"
      @enqueued_at = enqueued_at
    end
  end

  # ActiveJob >= 7.1 also carries scheduled_at: set by set(wait:) and by retry_on backoff.
  class DummyScheduledJob < DummyPerfJob
    attr_reader :scheduled_at

    def initialize(scheduled_at:, **kwargs)
      super(**kwargs)
      @scheduled_at = scheduled_at
    end
  end

  describe "#record — duration threshold (slow_job)" do
    it "sends above the threshold (X+1) on the /metrics path with the job fields" do
      enable!(slow_job_threshold_ms: 100)
      stub_request(:post, url)

      described_class.new.record(job_class: "ReportJob", queue: "low", adapter: "active_job",
                                 duration_ms: 101, attempt: 1, trace_id: "t-1")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body["kind"] == "performance_issue" && body["subtype"] == "slow_job" &&
          body["label"] == "ReportJob" && body["queue"] == "low" &&
          body["adapter"] == "active_job" && body["trace_id"] == "t-1" &&
          body["duration_ms"] == 101
      }
    end

    it "does not send at the exact threshold (X) nor below (X-1) — normal jobs make no noise" do
      enable!(slow_job_threshold_ms: 100)
      stub = stub_request(:post, url)

      subscriber = described_class.new
      subscriber.record(job_class: "FastJob", duration_ms: 100)
      subscriber.record(job_class: "FastJob", duration_ms: 99)

      expect(stub).not_to have_been_requested
    end
  end

  describe "#record — wait threshold (job_queue_latency)" do
    it "sends above the threshold with subtype job_queue_latency" do
      enable!(job_queue_latency_threshold_ms: 1000)
      stub_request(:post, url)

      described_class.new.record(job_class: "SlowQueueJob", queue: "default",
                                 queue_latency_ms: 5000, trace_id: "t-2")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body["subtype"] == "job_queue_latency" && body["duration_ms"] == 5000 &&
          body["label"] == "SlowQueueJob"
      }
    end
  end

  describe "#record — duration AND wait together (N=2 metrics)" do
    it "emits two distinct metrics when both exceed the threshold" do
      enable!(slow_job_threshold_ms: 100, job_queue_latency_threshold_ms: 100)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "HeavyJob", duration_ms: 500, queue_latency_ms: 500,
                                 trace_id: "t-3")

      expect(stub).to have_been_requested.twice
      expect(WebMock).to have_requested(:post, url).with { |r| JSON.parse(r.body)["subtype"] == "slow_job" }
      expect(WebMock).to have_requested(:post, url).with { |r| JSON.parse(r.body)["subtype"] == "job_queue_latency" }
    end
  end

  describe "#record — master switch and sampling" do
    it "emits nothing when monitor_jobs is OFF" do
      enable!(monitor_jobs: false, slow_job_threshold_ms: 1)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "AnyJob", duration_ms: 9999)

      expect(stub).not_to have_been_requested
    end

    it "sends nothing with jobs_sample_rate 0.0 even above the threshold (deterministic)" do
      enable!(slow_job_threshold_ms: 1, jobs_sample_rate: 0.0)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "AnyJob", duration_ms: 9999)

      expect(stub).not_to have_been_requested
    end

    it "intermediate sampling: sends when Random.rand < rate" do
      enable!(slow_job_threshold_ms: 1, jobs_sample_rate: 0.5)
      allow(Random).to receive(:rand).and_return(0.4)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "AnyJob", duration_ms: 9999)

      expect(stub).to have_been_requested
    end

    it "intermediate sampling: drops when Random.rand >= rate" do
      enable!(slow_job_threshold_ms: 1, jobs_sample_rate: 0.5)
      allow(Random).to receive(:rand).and_return(0.6)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "AnyJob", duration_ms: 9999)

      expect(stub).not_to have_been_requested
    end

    it "does not sample jobs below the threshold (no wasted Random.rand, no send)" do
      enable!(slow_job_threshold_ms: 100, jobs_sample_rate: 1.0)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "FastJob", duration_ms: 10)

      expect(stub).not_to have_been_requested
    end
  end

  describe "#record — retried/discarded job" do
    it "a discarded but not slow job makes no noise (the outcome is not a metric in itself)" do
      enable!(slow_job_threshold_ms: 100)
      stub = stub_request(:post, url)

      described_class.new.record(job_class: "GiveUpJob", duration_ms: 5, attempt: 5, trace_id: "x")

      expect(stub).not_to have_been_requested
    end

    it "a discarded but slow job is measured, with the high attempt in the metric" do
      enable!(slow_job_threshold_ms: 100)
      stub_request(:post, url)

      described_class.new.record(job_class: "GiveUpJob", duration_ms: 500, attempt: 5, trace_id: "x")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body["subtype"] == "slow_job" && body["attempt"] == 5 && body["label"] == "GiveUpJob"
      }
    end
  end

  describe "#record — isolation between concurrent jobs" do
    it "does not mix the data of two distinct jobs (logic without shared state)" do
      enable!(slow_job_threshold_ms: 10)
      stub_request(:post, url)
      subscriber = described_class.new

      subscriber.record(job_class: "JobA", duration_ms: 100, trace_id: "a")
      subscriber.record(job_class: "JobB", duration_ms: 100, trace_id: "b")

      expect(WebMock).to have_requested(:post, url).with { |r|
        body = JSON.parse(r.body)
        body["label"] == "JobA" && body["trace_id"] == "a"
      }
      expect(WebMock).to have_requested(:post, url).with { |r|
        body = JSON.parse(r.body)
        body["label"] == "JobB" && body["trace_id"] == "b"
      }
    end
  end

  describe "#active_job_started / #active_job_performed (ActiveJob duck-typed)" do
    let(:base) { Time.utc(2026, 1, 1, 12, 0, 0) }

    it "computes the wait from enqueued_at and emits job_queue_latency" do
      enable!(job_queue_latency_threshold_ms: 60_000)
      stub_request(:post, url)
      job = DummyPerfJob.new(enqueued_at: base, executions: 2)

      described_class.new.active_job_started(job, now: base + 120) # 120_000 ms of wait

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body["subtype"] == "job_queue_latency" && body["label"] == "DummyPerfJob" &&
          body["queue"] == "mailers" && body["attempt"] == 2 && body["trace_id"] == "j-1" &&
          body["duration_ms"] == 120_000.0
      }
    end

    # CYRB-27: a job delayed on purpose that starts on time is not waiting in the queue.
    it "does not count a planned delay as queue wait" do
      enable!(job_queue_latency_threshold_ms: 60_000)
      stub = stub_request(:post, url)
      job = DummyScheduledJob.new(enqueued_at: base, scheduled_at: base + 600)

      described_class.new.active_job_started(job, now: base + 630) # on time + 30 s

      expect(stub).not_to have_been_requested
    end

    it "measures the wait from the scheduled time when the job starts late" do
      enable!(job_queue_latency_threshold_ms: 60_000)
      stub_request(:post, url)
      job = DummyScheduledJob.new(enqueued_at: base, scheduled_at: base + 600)

      described_class.new.active_job_started(job, now: base + 720)

      expect(WebMock).to have_requested(:post, url).with { |req|
        JSON.parse(req.body)["duration_ms"] == 120_000.0
      }
    end

    it "falls back to enqueued_at when scheduled_at is missing or earlier" do
      enable!(job_queue_latency_threshold_ms: 60_000)
      stub_request(:post, url)
      job = DummyScheduledJob.new(enqueued_at: base, scheduled_at: base - 30)

      described_class.new.active_job_started(job, now: base + 120)

      expect(WebMock).to have_requested(:post, url).with { |req|
        JSON.parse(req.body)["duration_ms"] == 120_000.0
      }
    end

    it "emits no wait when enqueued_at is missing (adapter that does not populate it)" do
      enable!(job_queue_latency_threshold_ms: 1)
      stub = stub_request(:post, url)
      job = DummyPerfJob.new(enqueued_at: nil)

      described_class.new.active_job_started(job, now: base)

      expect(stub).not_to have_been_requested
    end

    it "emits slow_job with the execution duration and the attempt (visible retry)" do
      enable!(slow_job_threshold_ms: 200)
      stub_request(:post, url)
      job = DummyPerfJob.new(executions: 3)

      described_class.new.active_job_performed(job, 250.5)

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body["subtype"] == "slow_job" && body["label"] == "DummyPerfJob" &&
          body["attempt"] == 3 && body["duration_ms"] == 250.5 && body["adapter"] == "active_job"
      }
    end
  end

  describe ".latency_ms" do
    let(:now) { Time.utc(2026, 1, 1, 0, 0, 30) }

    it "returns the wait milliseconds from a Time" do
      expect(described_class.latency_ms(Time.utc(2026, 1, 1, 0, 0, 0), now: now)).to eq(30_000.0)
    end

    it "returns the milliseconds from a numeric epoch (seconds, e.g. Sidekiq)" do
      expect(described_class.latency_ms(now.to_f - 5, now: now)).to be_within(1.0).of(5000.0)
    end

    it "returns the milliseconds from an ISO8601 string" do
      expect(described_class.latency_ms("2026-01-01T00:00:00Z", now: now)).to eq(30_000.0)
    end

    it "maps nil to nil (no wait metric)" do
      expect(described_class.latency_ms(nil, now: now)).to be_nil
    end

    it "returns nil for an unparsable string" do
      expect(described_class.latency_ms("not-a-date", now: now)).to be_nil
    end

    it "clamps to 0 when negative (clock skew: enqueued in the future)" do
      expect(described_class.latency_ms(now + 10, now: now)).to eq(0.0)
    end
  end
end
