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
