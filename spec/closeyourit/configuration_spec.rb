# frozen_string_literal: true

RSpec.describe CloseYourIt::Configuration do
  describe "CloseYourIt.init" do
    it "returns the configuration and stores it" do
      returned = CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok_123"
        c.project_id = "proj-1"
      end

      expect(returned).to be_a(described_class)
      expect(CloseYourIt.configuration).to be(returned)
      expect(CloseYourIt.configuration.token).to eq("tok_123")
    end
  end

  describe "default values" do
    subject(:config) { described_class.new }

    it "excludes RoutingError and RecordNotFound" do
      expect(config.excluded_exceptions).to include(
        "ActionController::RoutingError",
        "ActiveRecord::RecordNotFound"
      )
    end

    it "has PII off and obfuscated SQL by default" do
      expect(config.send_pii).to be(false)
      expect(config.obfuscate_sql).to be(true)
    end

    it "has the default slow thresholds" do
      expect(config.slow_query_threshold_ms).to eq(100)
      expect(config.slow_method_threshold_ms).to eq(200)
    end

    it "has bind/argument capture OFF by default (privacy opt-in)" do
      expect(config.capture_query_bindings).to be(false)
      expect(config.capture_method_arguments).to be(false)
    end

    it "has at least one background thread" do
      expect(config.async_threads).to be >= 1
    end

    it "has signal trapping OFF by default (opt-in: it overrides the host app handler)" do
      expect(config.trap_signals).to be(false)
    end

    it "has no diagnostic hook by default (opt-in)" do
      expect(config.on_diagnostic).to be_nil
    end
  end

  describe "#on_diagnostic" do
    subject(:config) { described_class.new }

    it "is writable with a callable" do
      hook = ->(event, details) { [ event, details ] }
      config.on_diagnostic = hook
      expect(config.on_diagnostic).to be(hook)
    end
  end

  describe "#enabled? — no-op without credentials" do
    def config_with(**over)
      described_class.new.tap do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        over.each { |k, v| c.public_send("#{k}=", v) }
      end
    end

    it "is false without token" do
      expect(config_with(token: nil).enabled?).to be(false)
    end

    it "is false without endpoint_url" do
      expect(config_with(endpoint_url: nil).enabled?).to be(false)
    end

    it "is false without project_id" do
      expect(config_with(project_id: nil).enabled?).to be(false)
    end

    it "is true with https endpoint + token + project_id" do
      expect(config_with.enabled?).to be(true)
    end
  end

  describe "HTTPS guard" do
    it "rejects http:// in production (no-op) and logs a warning" do
      fake_logger = instance_double(Logger, warn: nil)
      allow(CloseYourIt).to receive(:internal_logger).and_return(fake_logger)

      config = CloseYourIt.init do |c|
        c.endpoint_url = "http://insecure.test"
        c.token = "tok"
        c.project_id = "proj-1"
        c.environment = "production"
      end

      expect(config.enabled?).to be(false)
      expect(fake_logger).to have_received(:warn).with(/http/i)
    end

    it "allows http:// in development (with a warning)" do
      fake_logger = instance_double(Logger, warn: nil)
      allow(CloseYourIt).to receive(:internal_logger).and_return(fake_logger)

      config = CloseYourIt.init do |c|
        c.endpoint_url = "http://localhost:3011"
        c.token = "tok"
        c.project_id = "proj-1"
        c.environment = "development"
      end

      expect(config.enabled?).to be(true)
      expect(fake_logger).to have_received(:warn).with(/http/i)
    end
  end

  describe "setter normalization" do
    it "converts excluded_exceptions to strings" do
      config = described_class.new
      config.excluded_exceptions = [ RuntimeError, "My::Error" ]
      expect(config.excluded_exceptions).to eq(%w[RuntimeError My::Error])
    end

    # CYRB-17: a String is LITERAL text, not a pattern. Whoever writes "Error in thread (0.0ms)" does
    # not expect the parentheses and the dot to act as metacharacters, so it must be escaped.
    it "converts excluded_log_patterns to Regexps, escaping strings" do
      config = described_class.new
      config.excluded_log_patterns = [ /already Regexp/, "Error in thread (0.0ms)" ]

      expect(config.excluded_log_patterns).to eq([ /already Regexp/, /Error\ in\ thread\ \(0\.0ms\)/ ])
      expect(config.excluded_log_patterns.last).to match("SolidQueue Error in thread (0.0ms) boom")
      expect(config.excluded_log_patterns.last).not_to match("Error in thread X0X0ms")
    end
  end

  describe "excluded_log_patterns (broadcast noise that is not an exception — CYRB-17)" do
    it "is empty by default: no log is silenced without an explicit choice" do
      expect(described_class.new.excluded_log_patterns).to eq([])
    end
  end

  describe "excluded_query_patterns (framework service tables — CYRB-18)" do
    it "excludes the Solid stack tables by default" do
      patterns = described_class.new.excluded_query_patterns

      expect(patterns).to eq([ /\bsolid_queue_/, /\bsolid_cache_/, /\bsolid_cable_/ ])
    end

    it "can be cleared to measure service queries too" do
      config = described_class.new
      config.excluded_query_patterns = []

      expect(config.excluded_query_patterns).to eq([])
    end

    it "converts Strings to escaped literal text" do
      config = described_class.new
      config.excluded_query_patterns = [ "pg_stat_activity" ]

      expect(config.excluded_query_patterns.first).to match("SELECT count(*) FROM pg_stat_activity")
    end
  end

  describe "#project_root (base for the relative frame filename — CYRB-4)" do
    it "uses the explicitly set value" do
      config = described_class.new
      config.project_root = "/srv/app"
      expect(config.project_root).to eq("/srv/app")
    end

    it "auto-detects the working directory when not set (outside Rails)" do
      expect(described_class.new.project_root).to eq(Dir.pwd)
    end

    it "uses Rails.root when Rails is present" do
      fake_rails = double("Rails", root: Pathname.new("/rails/app_root"))
      stub_const("Rails", fake_rails)
      expect(described_class.new.project_root).to eq("/rails/app_root")
    end
  end

  describe "structured log defaults" do
    subject(:config) { described_class.new }

    it { expect(config.logs_enabled).to be(true) }
    it { expect(config.logs_sample_rate).to eq(1.0) }
    it { expect(config.logs_batch_size).to eq(50) }
    it { expect(config.logs_flush_interval).to eq(5) }
    it { expect(config.capture_rails_logs).to be(false) }
    it { expect(config.logs_min_level).to eq(:info) }
    it { expect(config.capture_rails_logs_min_level).to eq(:warn) }

    # CYRB-7: the Rails.logger broadcast threshold is by default more conservative (:warn) than
    # logs_min_level (:info), so `capture_rails_logs = true` does not flood the stream with framework
    # info noise (Started GET, Rendered, ...). The two thresholds are separate and configurable.
    it "uses a higher threshold than logs_min_level for the Rails.logger broadcast" do
      expect(CloseYourIt::LogEvent.severity(config.capture_rails_logs_min_level))
        .to be > CloseYourIt::LogEvent.severity(config.logs_min_level)
    end

    it "exposes capture_rails_logs_min_level as a writable option" do
      config.capture_rails_logs_min_level = :error
      expect(config.capture_rails_logs_min_level).to eq(:error)
    end
  end
end
