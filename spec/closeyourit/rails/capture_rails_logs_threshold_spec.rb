# frozen_string_literal: true

# Regression for ticket CYRB-7: with `capture_rails_logs = true` the railtie built the Rails.logger
# LogBroadcast with `logs_min_level` (default :info) as threshold → in high-traffic production EVERY
# framework info line (Started GET, Rendered, ...) was forwarded, saturating the stream with tens of
# thousands of log entries/min. The fix introduces a DEDICATED threshold
# `capture_rails_logs_min_level` (default :warn, more conservative and separate from logs_min_level)
# used by the railtie to build the broadcast. These tests tie config and railtie wiring to the fix: if
# one part regresses, the suite turns red. Public copy (CYRA-1054): the maintainer repository also
# checks that its README documents the option; this README links the full guide instead.
RSpec.describe "CYRB-7 — dedicated threshold for the Rails.logger broadcast" do
  let(:railtie_source) do
    File.read(File.expand_path("../../../lib/closeyourit/rails/railtie.rb", __dir__))
  end

  it "exposes capture_rails_logs_min_level on the Configuration (getter + setter)" do
    config = CloseYourIt::Configuration.new
    expect(config).to respond_to(:capture_rails_logs_min_level)
    expect(config).to respond_to(:capture_rails_logs_min_level=)
  end

  it "uses :warn as default, more conservative than logs_min_level (:info)" do
    config = CloseYourIt::Configuration.new
    expect(config.capture_rails_logs_min_level).to eq(:warn)
    expect(CloseYourIt::LogEvent.severity(:warn))
      .to be > CloseYourIt::LogEvent.severity(config.logs_min_level)
  end

  it "the railtie builds the LogBroadcast with capture_rails_logs_min_level" do
    expect(railtie_source).to match(/LogBroadcast\.new\(config\.capture_rails_logs_min_level\)/)
  end

  it "the railtie no longer uses logs_min_level to build the broadcast (regression)" do
    expect(railtie_source).not_to include("LogBroadcast.new(config.logs_min_level)")
  end
end
