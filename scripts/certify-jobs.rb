# frozen_string_literal: true

# Private JSONL protocol for an owned loopback Redis and SDK/backend certification.
require "json"
require "uri"
require "logger"
require "digest"
$stdout = File.open(File::NULL, "w")
require "active_job"
require "sidekiq"
require "sidekiq/api"
require "active_job/queue_adapters/sidekiq_adapter"
require "closeyourit-ruby"

module CertificationJobs
  LOCK = Mutex.new
  ATTEMPTS = Hash.new(0)
  EXECUTIONS = []
  OBSERVED = []
  FINISHED = []
  class CompletionMiddleware
    def call(_worker, job, _queue)
      value = yield
      LOCK.synchronize { FINISHED << job.fetch("jid") }
      value
    end
  end
  PRIVATE_ARGUMENT = "synthetic-private-job-argument"
  PHASES = %w[baseline disabled enabled outage uninstalled].freeze

  def self.execute(framework, id, mode)
    count = LOCK.synchronize { ATTEMPTS[id] += 1 }
    outcome = mode == "failure" || (mode == "retry" && count == 1) ? "error" : "success"
    LOCK.synchronize do
      EXECUTIONS << { framework: framework, job_id: id, mode: mode, observed_attempt: count,
                      application_outcome: outcome, observed_at: Time.now.utc.iso8601(6) }
    end
    raise ArgumentError, "Certification job failed" if outcome == "error"
    42
  end

  class ActiveTask < ActiveJob::Base
    include CloseYourIt::Rails::ActiveJobExtension
    sidekiq_options retry: false
    retry_on ArgumentError, wait: 1, attempts: 2, jitter: 0

    def perform(mode, _private_argument)
      CertificationJobs.execute("active_job", job_id, mode)
    end
  end

  class FailedTask < ActiveJob::Base
    include CloseYourIt::Rails::ActiveJobExtension
    sidekiq_options retry: false
    def perform(mode, _private_argument)
      CertificationJobs.execute("active_job", job_id, mode)
    end
  end

  class NativeTask
    include Sidekiq::Job
    sidekiq_options retry: false

    def perform(mode, _private_argument)
      CertificationJobs.execute("sidekiq", jid, mode)
    end
  end

  class RetriedTask < NativeTask
    sidekiq_options retry: 1
    sidekiq_retry_in { 1 }
  end

  def self.observe(payload)
    context = payload.dig("contexts", "job") || payload.dig("attributes", "contexts", "job")
    error_context = payload.dig("contexts", "active_job") || payload.dig("contexts", "sidekiq")
    LOCK.synchronize do
      OBSERVED << { event_id: payload["event_id"], sample_id: payload["sample_id"],
                    kind: payload["kind"], subtype: payload["subtype"], logger: payload["logger"],
                    label: payload["label"], duration_ms: payload["duration_ms"], level: payload["level"],
                    handled: payload.dig("exception", "values")&.last&.dig("mechanism", "handled"),
                    job: context, error_job: error_context,
                    private_arguments_absent: !JSON.generate(payload).include?(PRIVATE_ARGUMENT) }
    end
    payload
  end

  def self.loopback!(value, schemes)
    uri = URI.parse(value)
    raise ArgumentError, "Loopback endpoint required" unless schemes.include?(uri.scheme) && %w[127.0.0.1 localhost ::1].include?(uri.hostname)
    value
  end

  def self.configure_sdk(config, phase)
    CloseYourIt.init do |sdk|
      sdk.endpoint_url = loopback!(config.fetch(phase == "outage" ? "outage_endpoint" : "endpoint"), %w[http])
      sdk.token = %w[baseline disabled].include?(phase) ? nil : config.fetch("token")
      sdk.project_id = config.fetch("project_id")
      sdk.environment = config.fetch("environment")
      sdk.release = "#{config.fetch('release')}-#{phase}"
      sdk.report_active_job_errors = !%w[baseline uninstalled].include?(phase)
      sdk.usage_enabled = false
      sdk.async_threads = 0
      sdk.job_lifecycle_logs = true
      sdk.logs_batch_size = 1
      sdk.logs_flush_interval = 0
      sdk.slow_job_threshold_ms = -1
      sdk.job_queue_latency_threshold_ms = -1
      sdk.before_send = method(:observe)
    end
    CloseYourIt.internal_logger = Logger.new(File::NULL)
  end

  def self.enqueue(queue)
    jobs = []
    %w[success failure retry scheduled].each do |mode|
      klass = mode == "failure" ? FailedTask : ActiveTask
      job = klass.set(queue: queue, wait: mode == "scheduled" ? 1 : 0).perform_later(mode, PRIVATE_ARGUMENT)
      jobs << { framework: "active_job", job_id: job.job_id, mode: mode, expected_attempts: mode == "retry" ? 2 : 1 }
      worker = mode == "retry" ? RetriedTask : NativeTask
      id = if mode == "scheduled"
        worker.set(queue: queue).perform_in(1, mode, PRIVATE_ARGUMENT)
      else
        worker.set(queue: queue).perform_async(mode, PRIVATE_ARGUMENT)
      end
      jobs << { framework: "sidekiq", job_id: id, mode: mode, expected_attempts: mode == "retry" ? 2 : 1 }
    end
    jobs
  end

  def self.emit(value)
    STDOUT.puts(JSON.generate(value))
    STDOUT.flush
  end

  def self.run
    config = JSON.parse(STDIN.gets || "")
    raise ArgumentError, "Invalid run identity" unless config.fetch("run_id").match?(/\A[0-9a-f]{16}\z/)
    broker = loopback!(config.fetch("broker_url"), %w[redis])
    queue = "certification-#{config.fetch('run_id')}-ruby"
    logger = Logger.new(File::NULL)
    ActiveJob::Base.logger = logger
    ActiveJob::Base.queue_adapter = :sidekiq
    worker = Sidekiq.configure_embed do |sidekiq|
      sidekiq.redis = { url: broker }
      sidekiq.logger = logger
      sidekiq.concurrency = 1
      sidekiq.queues = [ queue ]
      sidekiq[:poll_interval_average] = 0.1
      sidekiq[:timeout] = 5
      sidekiq.server_middleware { |chain| chain.add(CompletionMiddleware) }
      sidekiq.error_handlers.clear
      sidekiq.error_handlers << ->(error, context, _) do
        begin
          CloseYourIt::Sidekiq::ErrorHandler.new.call(error, context) if CloseYourIt.enabled? && CloseYourIt.configuration.report_active_job_errors
        ensure
          LOCK.synchronize { FINISHED << context.fetch(:job).fetch("jid") }
        end
      end
    end
    worker.run
    subscriber = CloseYourIt::Subscribers::JobPerformance.new
    sdk_root = Gem.loaded_specs.fetch("closeyourit-ruby").full_gem_path
    inventory = Dir.glob(File.join(sdk_root, "lib/**/*.rb")).to_h do |path|
      [ path.delete_prefix(sdk_root + "/"), Digest::SHA256.file(path).hexdigest ]
    end
    emit(type: "ready", framework: { ruby: RUBY_VERSION, active_job: ActiveJob::VERSION::STRING, sidekiq: Sidekiq::VERSION },
      sdk: { version: CloseYourIt::VERSION, path: sdk_root, inventory: inventory })
    PHASES.each do |phase|
      command = JSON.parse(STDIN.gets || "")
      break if command == { "command" => "stop" }
      raise ArgumentError, "Unexpected phase" unless command == { "command" => "next", "phase" => phase }
      configure_sdk(config, phase)
      stats_before = CloseYourIt.stats.snapshot
      chain = Sidekiq.default_configuration.server_middleware
      if %w[disabled enabled outage].include?(phase)
        subscriber.install
        chain.add(CloseYourIt::Sidekiq::JobMetricsMiddleware)
      else
        subscriber.uninstall
        chain.remove(CloseYourIt::Sidekiq::JobMetricsMiddleware)
      end
      LOCK.synchronize { EXECUTIONS.clear; OBSERVED.clear; FINISHED.clear }
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      jobs = enqueue(queue)
      deadline = start + 90
      loop do
        count = LOCK.synchronize { FINISHED.size }
        queued = Sidekiq::Queue.new(queue).size + Sidekiq::RetrySet.new.size + Sidekiq::ScheduledSet.new.size
        break if count == 10 && queued.zero?
        raise "Job completion deadline exceeded" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
      CloseYourIt.log(:info, "Job certification application completed", logger: "certification.application") if phase == "uninstalled"
      CloseYourIt.shutdown
      diagnostics = CloseYourIt.stats.snapshot.to_h { |key, value| [ key, value - stats_before.fetch(key) ] }
      executions, observed = LOCK.synchronize { [ EXECUTIONS.dup, OBSERVED.dup ] }
      emit(type: "phase", phase: phase, jobs: jobs, executions: executions, observed: observed,
        diagnostics: diagnostics,
        elapsed_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000,
        telemetry_is_sender_observation: true)
    end
    worker.stop
    worker = nil
    emit(type: "completed", cleanup: { worker_stopped: true })
  ensure
    subscriber&.uninstall
    worker&.stop
    CloseYourIt.shutdown
  end
end

begin
  CertificationJobs.run if $PROGRAM_NAME == __FILE__
rescue StandardError
  CertificationJobs.emit(type: "failed", reason: "producer_failed")
  exit 1
end
