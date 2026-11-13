# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe CloseYourIt::ErrorEvent do
  let(:config) do
    CloseYourIt::Configuration.new.tap do |c|
      c.environment = "test"
      c.project_id = "proj-1"
    end
  end

  # Raises inside a rescue: Ruby sets `cause` automatically.
  def exception_with_cause
    begin
      raise ArgumentError, "root cause"
    rescue ArgumentError
      raise RuntimeError, "outer message"
    end
  rescue RuntimeError => e
    e
  end

  subject(:payload) { described_class.from_exception(exception_with_cause, configuration: config).to_h }

  it "has the Sentry event format (event_id hex32, level, timestamp, platform)" do
    expect(payload["level"]).to eq("error")
    expect(payload["platform"]).to eq("ruby")
    expect(payload["environment"]).to eq("test")
    expect(payload["event_id"]).to match(/\A[0-9a-f]{32}\z/)
    expect(payload["timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    expect(payload["sdk"]).to include("name" => "closeyourit-ruby")
  end

  it "includes the current scope trace_id (correlation with logs)" do
    CloseYourIt::Scope.current.trace_id = "trace-9"
    event = described_class.from_exception(StandardError.new("x"), configuration: config).to_h
    expect(event["trace_id"]).to eq("trace-9")
  ensure
    CloseYourIt.clear_scope
  end

  it "puts the main exception LAST in exception.values" do
    main = payload["exception"]["values"].last
    expect(main["type"]).to eq("RuntimeError")
    expect(main["value"]).to eq("outer message")
    expect(main["mechanism"]).to eq("type" => "ruby", "handled" => false)
  end

  it "has Sentry frames with filename/function/lineno/in_app" do
    frame = payload["exception"]["values"].last["stacktrace"]["frames"].first
    expect(frame.keys).to include("filename", "function", "lineno", "in_app")
  end

  it "includes the cause chain in values (cause first, main last)" do
    types = payload["exception"]["values"].map { |value| value["type"] }
    expect(types).to eq(%w[ArgumentError RuntimeError])
  end

  it "routes to the /events path" do
    event = described_class.from_exception(exception_with_cause, configuration: config)
    expect(event.ingest_path("proj-1")).to eq("/api/v1/projects/proj-1/events")
  end

  describe "context lines (code snippets in frames)" do
    def boom
      raise "boom" # source line expected in context_line
    end

    def raised_boom
      boom
    rescue RuntimeError => e
      e
    end

    def frame_of_raise(payload)
      payload["exception"]["values"].last["stacktrace"]["frames"].last
    end

    it "includes pre_context/context_line/post_context read from the source file" do
      frame = frame_of_raise(described_class.from_exception(raised_boom, configuration: config).to_h)

      expect(frame["context_line"]).to include('raise "boom"')
      expect(frame["pre_context"]).to be_an(Array)
      expect(frame["post_context"]).to be_an(Array)
      expect(frame["pre_context"].last).to include("def boom")
      expect(frame["post_context"].first).to include("end")
    end

    it "caps pre/post at the configured number of lines (default 3)" do
      frame = frame_of_raise(described_class.from_exception(raised_boom, configuration: config).to_h)

      expect(frame["pre_context"].size).to be <= 3
      expect(frame["post_context"].size).to be <= 3
    end

    it "omits the context with context_lines = 0" do
      config.context_lines = 0
      frame = frame_of_raise(described_class.from_exception(raised_boom, configuration: config).to_h)

      expect(frame).not_to have_key("context_line")
      expect(frame).not_to have_key("pre_context")
      expect(frame).not_to have_key("post_context")
    end

    it "omits the context for unreadable files without raising" do
      err = RuntimeError.new("no file")
      fake_loc = instance_double(Thread::Backtrace::Location,
                                 path: "/nonexistent/#{SecureRandom.hex(4)}.rb",
                                 label: "ghost", lineno: 10)
      allow(err).to receive(:backtrace_locations).and_return([ fake_loc ])

      frame = frame_of_raise(described_class.from_exception(err, configuration: config).to_h)

      # abs_path keeps the absolute path; filename is the basename (file outside project_root).
      expect(frame["abs_path"]).to start_with("/nonexistent/")
      expect(frame["filename"]).to eq(File.basename(fake_loc.path))
      expect(frame).not_to have_key("context_line")
    end

    # CYRB-40: the snippet is read only for in_app frames. The library file is real and readable,
    # so a missing snippet proves the read was skipped, not that it failed.
    context "with a library frame in the backtrace" do
      around do |example|
        Dir.mktmpdir do |dir|
          @gem_path = File.join(dir, "gems", "rack-3.0.0", "lib", "rack.rb")
          FileUtils.mkdir_p(File.dirname(@gem_path))
          File.write(@gem_path, "module Rack\n  def self.call\n    raise 'x'\n  end\nend\n")
          CloseYourIt::LineCache.clear
          example.run
        ensure
          CloseYourIt::LineCache.clear
        end
      end

      let(:app_line) { __LINE__ } # this very line is the app frame's context_line

      def library_event(config)
        err = RuntimeError.new("from a gem")
        app_loc = instance_double(Thread::Backtrace::Location, path: __FILE__, label: "app", lineno: app_line)
        gem_loc = instance_double(Thread::Backtrace::Location, path: @gem_path, label: "call", lineno: 3)
        allow(err).to receive(:backtrace_locations).and_return([ gem_loc, app_loc ])
        described_class.from_exception(err, configuration: config).to_h
      end

      def frame_for(payload, path)
        payload["exception"]["values"].last["stacktrace"]["frames"].find { |f| f["abs_path"] == path }
      end

      it "keeps the context for app frames and omits it for library frames" do
        payload = library_event(config)
        app_frame = frame_for(payload, __FILE__)
        gem_frame = frame_for(payload, @gem_path)

        expect(app_frame["in_app"]).to be(true)
        expect(app_frame["context_line"]).to include("let(:app_line)")
        expect(gem_frame["in_app"]).to be(false)
        expect(gem_frame).to include("filename" => "rack.rb", "function" => "call", "lineno" => 3)
        expect(gem_frame.keys).not_to include("pre_context", "context_line", "post_context")
      end

      it "never asks the line cache for a library file" do
        allow(CloseYourIt::LineCache).to receive(:lines).and_call_original
        library_event(config)

        expect(CloseYourIt::LineCache).to have_received(:lines).with(__FILE__)
        expect(CloseYourIt::LineCache).not_to have_received(:lines).with(@gem_path)
      end

      it "reads no file at all with context_lines = 0" do
        config.context_lines = 0
        allow(CloseYourIt::LineCache).to receive(:lines).and_call_original
        library_event(config)

        expect(CloseYourIt::LineCache).not_to have_received(:lines)
      end
    end
  end

  # CYRB-4: frame.filename must be relative/basename (like Dart/JS), not the absolute path,
  # so the culprit ("filename in function") is comparable across SDKs on polyglot projects.
  # abs_path stays the absolute path for the detail view.
  describe "frame.filename (relative/basename path, cross-SDK culprit — CYRB-4)" do
    # Builds the event from a controlled backtrace: the frame paths are deterministic.
    def event_from(config, *locations)
      err = RuntimeError.new("boom")
      allow(err).to receive(:backtrace_locations).and_return(locations)
      described_class.from_exception(err, configuration: config).to_h
    end

    def loc(path:, label: "create", lineno: 10)
      instance_double(Thread::Backtrace::Location, path: path, label: label, lineno: lineno)
    end

    def first_frame(payload)
      payload.dig("exception", "values", 0, "stacktrace", "frames", 0)
    end

    before { config.context_lines = 0 } # fake paths: no source reading

    it "uses the path relative to project_root for app code; abs_path stays absolute" do
      config.project_root = "/rails"
      frame = first_frame(event_from(config, loc(path: "/rails/app/models/user.rb")))

      expect(frame["filename"]).to eq("app/models/user.rb")
      expect(frame["abs_path"]).to eq("/rails/app/models/user.rb")
    end

    it "uses the basename for files outside project_root (gem/stdlib)" do
      config.project_root = "/rails"
      gem_path = "/usr/lib/ruby/gems/3.3.0/gems/activerecord-8.0/lib/active_record/base.rb"
      frame = first_frame(event_from(config, loc(path: gem_path)))

      expect(frame["filename"]).to eq("base.rb")
      expect(frame["abs_path"]).to eq(gem_path)
    end

    it "produces a 'filename in function' culprit without the absolute path (comparable across SDKs)" do
      config.project_root = "/rails"
      frame = first_frame(event_from(config, loc(path: "/rails/app/models/user.rb")))
      culprit = "#{frame['filename']} in #{frame['function']}"

      expect(culprit).to eq("app/models/user.rb in create")
      expect(culprit).not_to start_with("/")
    end

    it "normalizes a project_root with a trailing separator (no double slash)" do
      config.project_root = "/rails/"
      frame = first_frame(event_from(config, loc(path: "/rails/app/models/user.rb")))

      expect(frame["filename"]).to eq("app/models/user.rb")
    end

    it "does not treat as internal a directory that is only a partial prefix of the root" do
      config.project_root = "/rails"
      # /rails-legacy is NOT inside /rails/ → it must fall back to the basename, not "legacy/..."
      frame = first_frame(event_from(config, loc(path: "/rails-legacy/app/models/user.rb")))

      expect(frame["filename"]).to eq("user.rb")
      expect(frame["abs_path"]).to eq("/rails-legacy/app/models/user.rb")
    end
  end
end
