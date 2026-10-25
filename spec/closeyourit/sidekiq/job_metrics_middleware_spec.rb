# frozen_string_literal: true

RSpec.describe CloseYourIt::Sidekiq::JobMetricsMiddleware do
  # Spy subscriber: isolates the middleware from the threshold/sampling logic (tested separately) and
  # makes the DURATION deterministic by stubbing the monotonic clock around the yield.
  let(:subscriber) { instance_spy(CloseYourIt::Subscribers::JobPerformance) }
  let(:middleware) { described_class.new(subscriber) }

  # ActiveJob-on-Sidekiq: the real class is in job["wrapped"]; Sidekiq's retry_count is nil on the
  # first run, 0 on the first retry, 1 on the second, ...
  def sidekiq_job(**over)
    {
      "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      "wrapped" => "MailDeliveryJob",
      "queue" => "critical",
      "jid" => "jid-1",
      "enqueued_at" => Time.now.to_f - 2,
      "retry_count" => 1
    }.merge(over)
  end

  def record_args
    captured = nil
    allow(subscriber).to receive(:record) { |**kwargs| captured = kwargs }
    yield
    captured
  end

  it "times the job and delegates to #record with duration, queue, attempt, adapter and trace_id" do
    allow(Process).to receive(:clock_gettime).and_return(0.0, 6.0) # 6 s → 6000 ms

    executed = false
    args = record_args { middleware.call(:worker, sidekiq_job, "critical") { executed = true } }

    expect(executed).to be(true)
    expect(args).to include(
      job_class: "MailDeliveryJob", queue: "critical", adapter: "sidekiq",
      duration_ms: 6000.0, attempt: 3, trace_id: "jid-1"
    )
    expect(args[:queue_latency_ms]).to be_a(Float)
  end

  it "uses job['class'] as label when 'wrapped' is absent (native Sidekiq job)" do
    args = record_args { middleware.call(:worker, sidekiq_job("wrapped" => nil, "class" => "PlainWorker"), "critical") { } }

    expect(args[:job_class]).to eq("PlainWorker")
  end

  it "sets attempt = 1 on the first run (no retry_count)" do
    job = sidekiq_job
    job.delete("retry_count")
    args = record_args { middleware.call(:worker, job, "critical") { } }

    expect(args[:attempt]).to eq(1)
  end

  it "sets attempt = 2 on the first retry (retry_count = 0)" do
    args = record_args { middleware.call(:worker, sidekiq_job("retry_count" => 0), "critical") { } }

    expect(args[:attempt]).to eq(2)
  end

  it "measures and delegates even when the job raises, then re-raises the error unchanged" do
    expect do
      middleware.call(:worker, sidekiq_job, "critical") { raise "job boom" }
    end.to raise_error("job boom")

    expect(subscriber).to have_received(:record).once
  end

  it "an error in telemetry does not disturb the job (absorbed and logged)" do
    allow(subscriber).to receive(:record).and_raise(StandardError, "broken telemetry")
    allow(CloseYourIt.internal_logger).to receive(:error)

    expect { middleware.call(:worker, sidekiq_job, "critical") { } }.not_to raise_error
    expect(CloseYourIt.internal_logger).to have_received(:error).with(/broken telemetry/)
  end
end
