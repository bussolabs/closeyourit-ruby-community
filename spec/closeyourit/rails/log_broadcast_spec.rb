# frozen_string_literal: true

require "logger"

RSpec.describe CloseYourIt::Rails::LogBroadcast do
  before { allow(CloseYourIt).to receive(:log) }

  it "forwards logs >= threshold to CloseYourIt.log" do
    described_class.new(:warn).error("boom")
    expect(CloseYourIt).to have_received(:log).with("error", "boom")
  end

  it "drops logs below the threshold" do
    described_class.new(:warn).info("noise")
    expect(CloseYourIt).not_to have_received(:log)
  end

  it "warn maps to the warning level" do
    described_class.new(:debug).warn("careful")
    expect(CloseYourIt).to have_received(:log).with("warning", "careful")
  end

  it "uses :warn as the default broadcast threshold (conservative, CYRB-7)" do
    broadcast = described_class.new
    broadcast.info("Started GET \"/\" for 127.0.0.1")
    broadcast.warn("deprecation warned")

    expect(CloseYourIt).not_to have_received(:log).with("info", anything)
    expect(CloseYourIt).to have_received(:log).with("warning", "deprecation warned")
  end

  # CYRB-7: at the default :warn threshold the framework info noise (one line per request in
  # high-traffic production) does NOT reach the stream; only warn/error/fatal are forwarded.
  describe "boundary of the :warn threshold (X-1 / X / X+1)" do
    let(:broadcast) { described_class.new(:warn) }

    it "drops the framework info noise (X-1)" do
      broadcast.info("Rendered posts/index.html.erb (Duration: 2.1ms)")
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "forwards warnings (X)" do
      broadcast.warn("cache miss")
      expect(CloseYourIt).to have_received(:log).with("warning", "cache miss")
    end

    it "forwards errors (X+1)" do
      broadcast.error("job failed")
      expect(CloseYourIt).to have_received(:log).with("error", "job failed")
    end
  end

  # CYRB-17: the threshold alone cannot tell noise apart. An exception excluded from the ERRORS channel
  # is still recorded by Rails with `logger.error`, so it came back through the LOGS channel: on
  # 2026-07-30 it was 48,000 entries out of 49,985 in the cross-app stream, almost all
  # `ActionController::RoutingError` from missing favicons and bot scans — a class in the default exclusions.
  describe "exclusions on the message text" do
    let(:broadcast) { described_class.new(:warn) }

    # REAL production line (closeyourit-rails v0.59.4, 2026-07-30 07:45:02): the repeated request-id
    # and the newlines are part of the format, and they are what makes every entry unique and not dedupable.
    let(:routing_error) do
      "  \n[321d07eb-f175-4c71-b09e-8fed62e3ef84] ActionController::RoutingError " \
        "(No route matches [GET] \"/favicon.ico\"):\n[321d07eb-f175-4c71-b09e-8fed62e3ef84]   "
    end

    it "drops the line naming an exception already excluded from the errors channel" do
      broadcast.error(routing_error)
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "forwards an error that is not in the exclusion list" do
      broadcast.error("NoMethodError (undefined method 'total' for nil)")
      expect(CloseYourIt).to have_received(:log).with("error", /NoMethodError/)
    end

    it "drops noise matching excluded_log_patterns (Regexp)" do
      CloseYourIt.init { |c| c.excluded_log_patterns = [ /SolidQueue-[\d.]+ Error in thread/ ] }

      broadcast.error("SolidQueue-1.4.0 Error in thread (0.0ms) error: ActiveRecord::DatabaseConnectionError")
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "accepts a String in excluded_log_patterns and treats it as literal text" do
      CloseYourIt.init { |c| c.excluded_log_patterns = [ "Error in thread" ] }

      broadcast.error("SolidQueue-1.4.0 Error in thread (0.0ms)")
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "lets through what matches no configured pattern" do
      CloseYourIt.init { |c| c.excluded_log_patterns = [ /Error in thread/ ] }

      broadcast.error("payment declined by the network")
      expect(CloseYourIt).to have_received(:log).with("error", "payment declined by the network")
    end

    it "also applies the excluded_exceptions Regexp matchers to the line text" do
      CloseYourIt.init { |c| c.excluded_exceptions += [ /SQLite3::BusyException/ ] }

      broadcast.error("ActiveRecord::StatementTimeout: SQLite3::BusyException: database is locked")
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "does not silence everything when the list contains an empty matcher" do
      CloseYourIt.init { |c| c.excluded_exceptions = [ "", "ActiveRecord::RecordNotFound" ] }

      broadcast.error("any error")
      expect(CloseYourIt).to have_received(:log).with("error", "any error")
    end

    # `logger.error { ... }` is the canonical form to avoid building the string when not needed. The
    # filter must evaluate the text AFTER the yield: if it looked only at the positional argument (nil),
    # every lazy line would bypass the exclusions and the noise would come back that way.
    it "also filters the lazy block form" do
      broadcast.error { routing_error }
      expect(CloseYourIt).not_to have_received(:log)
    end

    it "forwards the lazy block form when the text is not excluded" do
      broadcast.error { "computed only when needed" }
      expect(CloseYourIt).to have_received(:log).with("error", "computed only when needed")
    end

    it "forwards nothing when there is no text (no message, block or progname)" do
      broadcast.error(nil)
      expect(CloseYourIt).not_to have_received(:log)
    end
  end
end

# CYRB-37: when the app points `internal_logger` at a logger CloseYourIt also collects, a failed send
# wrote its error there, the line was collected and sent, the send failed again… and the periodic
# flush kept the loop alive for as long as the ingest was down. These examples run the REAL path
# (logger → CloseYourIt.log → buffer → transport) with no stub on CloseYourIt.log; WebMock plays the
# broken ingest.
RSpec.describe "Internal messages written into a collected logger (CYRB-37)" do
  let(:endpoint) { "http://ingest.test" }
  let(:project_id) { "11111111-2222-3333-4444-555555555555" }
  let(:logs_path) { "/api/v1/projects/#{project_id}/logs" }
  let(:logs_url) { "#{endpoint}#{logs_path}" }
  let(:app_output) { StringIO.new }

  # Stands in for Rails.logger broadcasting to the CloseYourIt sink (ActiveSupport::BroadcastLogger):
  # every line goes to the app output AND to the sink.
  let(:broadcasting_logger_class) do
    Class.new(::Logger) do
      def initialize(io, sink)
        super(io)
        @sink = sink
      end

      def add(severity, message = nil, progname = nil, &block)
        super
        @sink.add(severity, message, progname, &block)
      end
    end
  end

  let(:rails_logger) { broadcasting_logger_class.new(app_output, CloseYourIt::Rails::LogBroadcast.new(:warn)) }

  # One POST to /logs carrying exactly these messages, in order.
  def logs_batch(*messages)
    a_request(:post, logs_url).with { |request| JSON.parse(request.body).map { |entry| entry["message"] } == messages }
  end

  before do
    @original_internal_logger = CloseYourIt.instance_variable_get(:@internal_logger)
    CloseYourIt.init do |c|
      c.endpoint_url = endpoint
      c.token = "tok"
      c.project_id = project_id
      c.async_threads = 0 # sends on the caller's thread: each flush is one observable POST
      c.logs_flush_interval = 0 # no timer: the examples flush by hand, as the timer would
      c.logs_batch_size = 100
    end
  end

  after do
    CloseYourIt.internal_logger = @original_internal_logger
  end

  shared_examples "a loop-free failed send" do |failure|
    before { failure.call(stub_request(:post, logs_url)) }

    it "sends the real logs once and nothing more on the following flushes" do
      3.times { |i| app_logger.warn("disk almost full #{i}") }
      3.times { CloseYourIt.flush_logs }

      expect(logs_batch("disk almost full 0", "disk almost full 1", "disk almost full 2")).to have_been_made.once
      expect(a_request(:post, logs_url)).to have_been_made.once
    end

    it "keeps collecting the real logs the app writes during the outage" do
      app_logger.warn("first")
      CloseYourIt.flush_logs
      app_logger.error("second")
      2.times { CloseYourIt.flush_logs }

      expect(logs_batch("first")).to have_been_made.once
      expect(logs_batch("second")).to have_been_made.once
      expect(a_request(:post, logs_url)).to have_been_made.twice
    end

    it "leaves the internal-message flag down after the failed send" do
      app_logger.warn("real line")
      CloseYourIt.flush_logs

      expect(CloseYourIt.in_internal_log?).to be(false)
    end
  end

  context "when internal_logger is the app logger broadcast to CloseYourIt" do
    let(:app_logger) { rails_logger }

    before { CloseYourIt.internal_logger = rails_logger }

    context "with the ingest unreachable" do
      it_behaves_like "a loop-free failed send", ->(stub) { stub.to_raise(Errno::ECONNREFUSED) }

      it "still writes the internal message to the app log" do
        stub_request(:post, logs_url).to_raise(Errno::ECONNREFUSED)
        app_logger.warn("real line")
        CloseYourIt.flush_logs

        expect(app_output.string).to include("CloseYourIt transport: Errno::ECONNREFUSED")
      end
    end

    context "with the ingest answering an error" do
      it_behaves_like "a loop-free failed send", ->(stub) { stub.to_return(status: 503) }

      it "still writes the internal message to the app log" do
        stub_request(:post, logs_url).to_return(status: 503)
        app_logger.warn("real line")
        CloseYourIt.flush_logs

        expect(app_output.string).to include("CloseYourIt transport: HTTP 503 on #{logs_path}")
      end
    end
  end

  context "when internal_logger is CloseYourIt.logger itself" do
    let(:app_logger) { CloseYourIt.logger }

    before { CloseYourIt.internal_logger = CloseYourIt.logger }

    context "with the ingest unreachable" do
      it_behaves_like "a loop-free failed send", ->(stub) { stub.to_raise(Errno::ECONNREFUSED) }
    end

    context "with the ingest answering an error" do
      it_behaves_like "a loop-free failed send", ->(stub) { stub.to_return(status: 503) }
    end
  end

  context "when internal_logger is a plain logger (the default terminal shape)" do
    it "writes the internal message as before and sends only the real log" do
      stub_request(:post, logs_url).to_raise(Errno::ECONNREFUSED)
      CloseYourIt.internal_logger = ::Logger.new(app_output)

      CloseYourIt.logger.warn("real line")
      2.times { CloseYourIt.flush_logs }

      expect(app_output.string).to match(/ERROR -- : CloseYourIt transport: Errno::ECONNREFUSED/)
      expect(logs_batch("real line")).to have_been_made.once
      expect(a_request(:post, logs_url)).to have_been_made.once
    end
  end

  # R-1 of the plan: an internal message written straight to `internal_logger` skips the guard and
  # reopens the loop. The one allowed call is the write inside CloseYourIt.internal_log itself.
  it "has no direct internal_logger write outside CloseYourIt.internal_log" do
    lib_root = File.expand_path("../../../lib", __dir__)
    allowed = "internal_logger.public_send(level, message)"
    offenders = Dir.glob(File.join(lib_root, "**", "*.rb")).flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        next unless line.match?(/internal_logger\s*\./)
        next if line.strip == allowed && file.end_with?("closeyourit-ruby.rb")

        "#{file}:#{index + 1}"
      end
    end

    expect(offenders).to be_empty
  end
end
