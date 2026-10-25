# frozen_string_literal: true

require "active_job"
require "sidekiq"

module JobContractExamples
  class RetryJob < ActiveJob::Base
    include CloseYourIt::Rails::ActiveJobExtension
    retry_on ArgumentError, wait: 1, attempts: 2, jitter: 0

    def perform
      raise ArgumentError, "attempt boundary" if executions == 1
      42
    end
  end

  class RescuedJob < ActiveJob::Base
    include CloseYourIt::Rails::ActiveJobExtension
    rescue_from(ArgumentError) { true }

    def perform
      raise ArgumentError, "handled boundary"
    end
  end

  class DiscardedJob < RescuedJob
    discard_on ArgumentError
  end

  class UnhandledJob < RescuedJob
    rescue_from(ArgumentError) { |error| raise error }
  end

  class AbortedJob < ActiveJob::Base
    include CloseYourIt::Rails::ActiveJobExtension
    before_perform { throw :abort }
    def perform = 42
  end

  class RejectingAdapter
    def enqueue_at(*) = raise(IOError, "queue unavailable")
    def enqueue(*) = raise(IOError, "queue unavailable")
  end

  class PlainWorker
    include Sidekiq::Job
    def perform = 42
  end
end

RSpec.describe "Job lifecycle on real framework objects" do
  let(:observed) { [] }
  let(:subscriber) { CloseYourIt::Subscribers::JobPerformance.new }

  before do
    ActiveJob::Base.logger = Logger.new(File::NULL)
    ActiveJob::Base.queue_adapter = :test
    CloseYourIt.init do |config|
      config.endpoint_url = "https://ingest.example.test"
      config.project_id = "12345678-1234-4234-8234-123456789abc"
      config.token = "test-only"
      config.async_threads = 0
      config.usage_enabled = false
      config.job_lifecycle_logs = true
      config.report_active_job_errors = false
      config.logs_enabled = true
      config.logs_batch_size = 1
      config.logs_flush_interval = 0
      config.slow_job_threshold_ms = 0
      config.before_send = ->(payload) { observed << payload; nil }
    end
  end

  after do
    subscriber.uninstall
    CloseYourIt.shutdown
  end

  def jobs
    observed.select { |item| item["logger"] == "closeyourit.jobs" }.map { |item| item.dig("attributes", "contexts", "job") }
  end

  it "records retry and success once with the original ActiveJob identity" do
    subscriber.install
    job = JobContractExamples::RetryJob.new
    job.perform_now
    retry_payload = job.class.queue_adapter.enqueued_jobs.last
    expect(ActiveJob::Base.execute(retry_payload)).to eq(42)
    expect(jobs.map { |context| context.values_at("attempt", "attempt_outcome", "terminal") }).to eq([
      [ 1, "retry", false ], [ 2, "success", true ]
    ])
    expect(jobs.map { |context| context["job_id"] }.uniq).to eq([ job.job_id ])
    expect(jobs.last["scheduled_delay_ms"]).to be > 0
  end

  it "does not call a custom rescue success and distinguishes explicit discard" do
    subscriber.install
    expect(JobContractExamples::RescuedJob.perform_now).to be_a(ArgumentError)
    JobContractExamples::DiscardedJob.perform_now
    expect(jobs.map { |context| context.values_at("attempt_outcome", "terminal") }).to eq([
      [ "unknown", nil ], [ "discarded", true ]
    ])
  end

  it "uses Sidekiq8 milliseconds and preserves an unknown terminal failure" do
    middleware = CloseYourIt::Sidekiq::JobMetricsMiddleware.new
    payload = { "class" => "JobContractExamples::PlainWorker", "jid" => "job-one", "enqueued_at" => ((Time.now.to_f - 2) * 1000).to_i }
    expect(middleware.call(JobContractExamples::PlainWorker.new, payload, "default") { 42 }).to eq(42)
    expect(jobs.first["queue_wait_ms"]).to be_between(1900, 5000)
    error = ArgumentError.new("original")
    expect { middleware.call(nil, payload, "default") { raise error } }.to raise_error { |raised| expect(raised).to equal(error) }
    expect(jobs.last.values_at("attempt_outcome", "terminal")).to eq([ "error", nil ])
  end

  it "keeps unhandled errors and aborted callbacks distinct from success" do
    subscriber.install.install
    expect { JobContractExamples::UnhandledJob.perform_now }.to raise_error(ArgumentError)
    JobContractExamples::AbortedJob.perform_now
    expect(jobs.map { |context| context.values_at("attempt_outcome", "terminal") }).to eq([
      [ "error", nil ], [ "unknown", nil ]
    ])
  end

  it "does not report a successful retry when the queue rejects enqueue" do
    subscriber.install
    JobContractExamples::RetryJob.queue_adapter = JobContractExamples::RejectingAdapter.new
    expect { JobContractExamples::RetryJob.perform_now }.to raise_error(IOError)
    expect(jobs.last.values_at("attempt_outcome", "terminal")).to eq([ "error", nil ])
  ensure
    JobContractExamples::RetryJob.queue_adapter = :test
  end

  it "does not double count an ActiveJob inside Sidekiq" do
    subscriber.install
    wrapper = { "class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "JobContractExamples::RescuedJob" }
    CloseYourIt::Sidekiq::JobMetricsMiddleware.new.call(nil, wrapper, "default") { JobContractExamples::RescuedJob.perform_now }
    expect(jobs.size).to eq(1)
    expect(jobs.first["framework"]).to eq("active_job")
  end

  it "preserves the job master switch even when lifecycle logging is opted in" do
    CloseYourIt.configuration.monitor_jobs = false
    subscriber.install
    JobContractExamples::RescuedJob.perform_now
    CloseYourIt::Sidekiq::JobMetricsMiddleware.new.call(nil, { "class" => "PlainWorker" }, "default") { 42 }
    expect(jobs).to be_empty
  end

  it "has one ActiveJob owner and does not uninstall another instance's subscriber" do
    subscriber.install
    other = CloseYourIt::Subscribers::JobPerformance.new.install
    other.uninstall
    JobContractExamples::RescuedJob.perform_now
    expect(jobs.size).to eq(1)
    expect(CloseYourIt::Subscribers::JobPerformance.active_job_installed?).to be(true)
  end

  it "does not emit lifecycle logs by default or after uninstall" do
    CloseYourIt.configuration.job_lifecycle_logs = false
    subscriber.install
    JobContractExamples::RescuedJob.perform_now
    expect(jobs).to be_empty
    subscriber.uninstall
    CloseYourIt.configuration.job_lifecycle_logs = true
    JobContractExamples::RescuedJob.perform_now
    expect(jobs).to be_empty
  end
end
