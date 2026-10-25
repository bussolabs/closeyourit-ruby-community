# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::ActiveJobExtension do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

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
  # It does NOT expose `after_discard` → it stands for ActiveJob < 7.1 (legacy fallback: monitor captures).
  class DummyJob
    attr_reader :job_id, :executions, :queue_name

    def initialize
      @job_id = "j-1"
      @executions = 2
      @queue_name = "mailers"
    end
  end

  # Mini replica of the ActiveJob 7.1+ contract (perform_now → rescue_with_handler → retry_on / after_discard),
  # modeled on the real source (activejob execution.rb + exceptions.rb). The bundle does NOT include
  # ActiveJob, so we reproduce the callback sequence here to pin down the retry behavior end-to-end.
  # It exposes `after_discard` like a modern ActiveJob::Base → it enables the correct path (CYRB-19).
  class RetryingJob
    class << self
      def around_perform_callbacks
        @around_perform_callbacks ||= []
      end

      def around_perform(&block)
        around_perform_callbacks << block
      end

      def after_discard_callbacks
        @after_discard_callbacks ||= []
      end

      def after_discard(&block)
        after_discard_callbacks << block
      end
    end

    include CloseYourIt::Rails::ActiveJobExtension

    attr_reader :job_id, :queue_name
    attr_accessor :executions

    def initialize(attempts:, failures:)
      @attempts = attempts
      @failures = failures
      @executions = 0
      @job_id = "j-1"
      @queue_name = "mailers"
    end

    # Replicates `perform_now`: runs the job inside the around_perform callbacks; while attempts are left
    # it retries (like retry_on re-enqueueing, WITHOUT after_discard), on the last one it calls
    # after_discard (like retry_stopped → run_after_discard_procs). Every attempt raises a new instance
    # (as in the real thing).
    def perform_now
      loop do
        self.executions += 1
        begin
          return run_around_perform { perform }
        rescue Exception => e # rubocop:disable Lint/RescueException
          next if executions < @attempts # enqueue_retry: no after_discard, retry

          run_after_discard_procs(e) # retry_stopped: final failure → after_discard once
          return
        end
      end
    end

    private

    def perform
      raise "job boom" if executions <= @failures

      :ok
    end

    def run_around_perform(&inner)
      chain = inner
      self.class.around_perform_callbacks.reverse_each do |callback|
        nested = chain
        chain = -> { callback.call(self, nested) }
      end
      chain.call
    end

    def run_after_discard_procs(exception)
      self.class.after_discard_callbacks.each { |callback| callback.call(self, exception) }
    end
  end

  it "runs the block and returns its value on success" do
    enable!
    result = described_class.monitor(DummyJob.new) { 42 }
    expect(result).to eq(42)
  end

  it "captures the job error (handled:false) with job.* tags and re-raises it" do
    enable!
    stub_request(:post, url)
    job = DummyJob.new

    expect { described_class.monitor(job) { raise "job boom" } }.to raise_error("job boom")

    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body.dig("tags", "job.class") == "DummyJob" &&
        body.dig("tags", "job.queue") == "mailers" &&
        body.dig("contexts", "active_job", "job_id") == "j-1" &&
        body.dig("exception", "values").last.dig("mechanism", "handled") == false
    }
  end

  it "resets the scope at the end of the job" do
    enable!
    described_class.monitor(DummyJob.new) { CloseYourIt.set_tag(:x, "1") }
    expect(CloseYourIt::Scope.current.to_event_hash).to eq({})
  end

  it "sets trace_id = job_id in the scope (logs and error of the same job share the trace_id)" do
    enable!
    captured = nil
    described_class.monitor(DummyJob.new) { captured = CloseYourIt::Scope.current.trace_id }
    expect(captured).to eq("j-1")
  end

  it "does not capture when report_active_job_errors is false" do
    enable!(report_active_job_errors: false)
    stub = stub_request(:post, url)
    expect { described_class.monitor(DummyJob.new) { raise "x" } }.to raise_error("x")
    expect(stub).not_to have_been_requested
  end

  it "dedups: the same instance captured by rack and job is sent only once" do
    enable!
    stub = stub_request(:post, url)
    shared = (raise "dup" rescue $!) # rubocop:disable Style/RescueModifier

    CloseYourIt.capture_exception(shared) # "rack" capture
    expect { described_class.monitor(DummyJob.new) { raise shared } }.to raise_error(shared)

    expect(stub).to have_been_requested.once
  end

  # --- CYRB-19: a retried error must not be reported once per attempt ---

  describe "wiring (self.included)" do
    it "registers after_discard on jobs that expose it (ActiveJob 7.1+)" do
      expect(RetryingJob.after_discard_callbacks.size).to eq(1)
    end

    it "neither registers after_discard nor fails on jobs that do not expose it (legacy fallback)" do
      legacy = Class.new do
        def self.around_perform(&block)
          (@registered ||= []) << block
        end

        class << self
          attr_reader :registered
        end

        include CloseYourIt::Rails::ActiveJobExtension
      end

      expect(legacy.registered.size).to eq(1) # only around_perform
      expect(legacy).not_to respond_to(:after_discard)
    end
  end

  describe "modern job with after_discard (ActiveJob 7.1+)" do
    it "monitor does NOT capture on the failing attempt: reporting is delegated to after_discard" do
      enable!
      stub = stub_request(:post, url)
      job = RetryingJob.new(attempts: 3, failures: 99)

      expect { described_class.monitor(job) { raise "boom" } }.to raise_error("boom")

      expect(stub).not_to have_been_requested
    end

    it "report_discarded reports ONE occurrence (handled:false) with the final attempt count" do
      enable!
      stub_request(:post, url)
      job = RetryingJob.new(attempts: 3, failures: 99)
      job.executions = 3

      described_class.report_discarded(job, RuntimeError.new("boom"))

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body.dig("tags", "job.class") == "RetryingJob" &&
          body.dig("contexts", "active_job", "executions") == 3 &&
          body.dig("exception", "values").last.dig("mechanism", "handled") == false
      }.once
    end

    it "report_discarded is a no-op when report_active_job_errors is false" do
      enable!(report_active_job_errors: false)
      stub = stub_request(:post, url)

      described_class.report_discarded(RetryingJob.new(attempts: 1, failures: 1), RuntimeError.new("x"))

      expect(stub).not_to have_been_requested
    end

    it "the final report keeps the tags/breadcrumbs added during perform (not only the standard context)" do
      enable!
      stub_request(:post, url)
      job = RetryingJob.new(attempts: 1, failures: 99)

      # `monitor` enriches the scope during perform and hands it to the job; `after_discard` picks it up.
      error = RuntimeError.new("boom")
      expect do
        described_class.monitor(job) do
          CloseYourIt.set_tag("tenant", "acme")
          CloseYourIt.add_breadcrumb(message: "step done")
          raise error
        end
      end.to raise_error(error)
      described_class.report_discarded(job, error)

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body)
        body.dig("tags", "tenant") == "acme" &&
          body.dig("tags", "job.class") == "RetryingJob" &&
          body.dig("breadcrumbs", "values").any? { |b| b["message"] == "step done" }
      }.once
    end
  end

  # End-to-end ticket scenarios, driven by the ActiveJob 7.1+ contract replicated in RetryingJob.
  describe "CYRB-19 scenarios (perform_now with retry)" do
    it "Scenario 1: a successful retry generates no error" do
      enable!
      stub = stub_request(:post, url)

      RetryingJob.new(attempts: 3, failures: 1).perform_now # fails once, succeeds on the 2nd attempt

      expect(stub).not_to have_been_requested
    end

    it "Scenario 2: the final failure generates a single occurrence" do
      enable!
      stub_request(:post, url)

      RetryingJob.new(attempts: 3, failures: 99).perform_now # exhausts the 3 attempts

      expect(WebMock).to have_requested(:post, url).once
    end
  end
end
