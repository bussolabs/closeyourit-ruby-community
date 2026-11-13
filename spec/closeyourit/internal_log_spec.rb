# frozen_string_literal: true

require "logger"
require "stringio"

# CYRB-37: the single path for the gem's own messages. While it writes, the internal-message flag is
# up, so a logger CloseYourIt also collects does not turn the message into a new log entry.
RSpec.describe "CloseYourIt.internal_log" do
  let(:output) { StringIO.new }

  # Records, for every line it receives, whether the flag was up at that moment.
  let(:recording_logger_class) do
    Class.new(::Logger) do
      attr_reader :flags

      def add(severity, message = nil, progname = nil, &block)
        (@flags ||= []) << CloseYourIt.in_internal_log?
        super
      end
    end
  end

  before { @original_internal_logger = CloseYourIt.instance_variable_get(:@internal_logger) }

  after do
    CloseYourIt.internal_logger = @original_internal_logger
    Thread.current[CloseYourIt::INTERNAL_LOG_GUARD] = nil
  end

  it "writes the message unchanged, at the given level" do
    CloseYourIt.internal_logger = ::Logger.new(output)

    CloseYourIt.internal_log(:warn, "CloseYourIt transport: HTTP 503 on /logs")

    expect(output.string).to match(/WARN -- : CloseYourIt transport: HTTP 503 on \/logs$/)
  end

  it "raises the flag only while the logger writes" do
    logger = recording_logger_class.new(output)
    CloseYourIt.internal_logger = logger

    CloseYourIt.internal_log(:error, "boom")

    expect(logger.flags).to eq([ true ])
    expect(CloseYourIt.in_internal_log?).to be(false)
  end

  it "restores the previous value when calls are nested" do
    inner = ::Logger.new(output)
    outer = Object.new
    nested_flags = []
    outer.define_singleton_method(:warn) do |message|
      CloseYourIt.internal_logger = inner
      CloseYourIt.internal_log(:error, "inner #{message}")
      nested_flags << CloseYourIt.in_internal_log?
    end
    CloseYourIt.internal_logger = outer

    CloseYourIt.internal_log(:warn, "outer")

    expect(nested_flags).to eq([ true ]) # still up after the inner call: the outer write is not over
    expect(CloseYourIt.in_internal_log?).to be(false)
  end

  it "restores the previous value when the logger raises, and lets the error through as before" do
    broken = Object.new
    broken.define_singleton_method(:error) { |_message| raise IOError, "closed stream" }
    CloseYourIt.internal_logger = broken

    expect { CloseYourIt.internal_log(:error, "boom") }.to raise_error(IOError, "closed stream")
    expect(CloseYourIt.in_internal_log?).to be(false)
  end

  it "keeps a flag that was already up" do
    CloseYourIt.internal_logger = ::Logger.new(output)
    Thread.current[CloseYourIt::INTERNAL_LOG_GUARD] = true

    CloseYourIt.internal_log(:warn, "nested")

    expect(CloseYourIt.in_internal_log?).to be(true)
  end

  it "does not raise the flag on other threads" do
    entered = Queue.new
    release = Queue.new
    blocking = Object.new
    blocking.define_singleton_method(:warn) do |_message|
      entered << true
      release.pop
    end
    CloseYourIt.internal_logger = blocking

    writer = Thread.new { CloseYourIt.internal_log(:warn, "slow write") }
    entered.pop
    other_thread_flag = Thread.new { CloseYourIt.in_internal_log? }.value
    release << true
    writer.join

    expect(other_thread_flag).to be(false)
    expect(CloseYourIt.in_internal_log?).to be(false)
  end

  # Open point of the plan, decided: the flag silences logs ONLY. Errors, messages, events and
  # diagnostic notifications written while it is up behave exactly as before.
  describe "what the flag leaves alone" do
    let(:events_url) { "http://ingest.test/api/v1/projects/11111111-2222-3333-4444-555555555555/events" }
    let(:diagnostics) { [] }

    before do
      seen = diagnostics
      CloseYourIt.init do |c|
        c.endpoint_url = "http://ingest.test"
        c.token = "tok"
        c.project_id = "11111111-2222-3333-4444-555555555555"
        c.async_threads = 0
        c.logs_flush_interval = 0
        c.on_diagnostic = ->(event, details) { seen << [ event, details ] }
      end
      stub_request(:post, events_url).to_return(status: 202)
      Thread.current[CloseYourIt::INTERNAL_LOG_GUARD] = true
    end

    it "drops a log entry" do
      expect(CloseYourIt.log(:error, "internal line")).to be_nil
      expect(CloseYourIt.instance_variable_get(:@log_buffer)).to be_nil
    end

    it "still captures an exception" do
      expect(CloseYourIt.capture_exception(RuntimeError.new("real failure"))).not_to be_nil
      expect(a_request(:post, events_url)).to have_been_made.once
    end

    it "still captures a message" do
      expect(CloseYourIt.capture_message("cache miss storm", level: "warning")).not_to be_nil
      expect(a_request(:post, events_url)).to have_been_made.once
    end

    it "still notifies the diagnostic hook and leaves its own guard untouched" do
      CloseYourIt.notify_diagnostic(:drop, reason: :network)

      expect(diagnostics).to eq([ [ :drop, { reason: :network } ] ])
      expect(Thread.current[CloseYourIt::DIAGNOSTIC_GUARD]).to be(false)
    end
  end
end
