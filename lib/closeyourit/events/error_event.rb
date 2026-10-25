# frozen_string_literal: true

require "securerandom"
require "socket"
require_relative "../event"
require_relative "../scrubber"
require_relative "../line_cache"

module CloseYourIt
  # Turns a Ruby exception into the **Sentry event payload** the CloseYourIt backend ingests
  # (Errors::Ingest::Normalize). Uses `backtrace_locations` (no regex) and puts the cause chain in
  # `exception.values` ordered from the outermost to the main one (Sentry: values.last = the crash).
  class ErrorEvent < Event
    def self.from_exception(exception, configuration:, handled: false, level: "error", contexts: nil)
      new(exception, configuration, handled: handled, level: level, contexts: contexts)
    end

    def initialize(exception, configuration, handled: false, level: "error", contexts: nil)
      super(configuration)
      @exception = exception
      @handled = handled
      @level = level
      @contexts = contexts
      @scrubber = Scrubber.new(configuration)
    end

    def to_h
      base = compact(
        "event_id" => SecureRandom.uuid.delete("-"),
        "timestamp" => @occurred_at,
        "platform" => "ruby",
        "level" => @level,
        # Log↔error correlation: same trace_id as the logs of the same request (populated by the Scope).
        "trace_id" => CloseYourIt::Scope.current.trace_id,
        "environment" => environment,
        "release" => @configuration.release,
        "server_name" => server_name,
        "exception" => { "values" => exception_values },
        "contexts" => { "runtime" => { "name" => "ruby", "version" => RUBY_VERSION } },
        "sdk" => sdk
      )
      # Merges the per-request/job context (user/tags/extra/contexts/request) collected in the Scope.
      merged = deep_merge(base, CloseYourIt::Scope.current.to_event_hash)
      # Extra context passed explicitly (e.g. rails_error from the ErrorReporter).
      @contexts ? deep_merge(merged, { "contexts" => @contexts }) : merged
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/events"
    end

    private

    # Cause chain → Sentry array: outermost cause first, main exception LAST.
    def exception_values
      chain = []
      seen = []
      current = @exception
      while current && !seen.include?(current)
        chain << single_exception(current)
        seen << current
        current = current.cause
      end
      chain.reverse
    end

    def single_exception(exception)
      {
        "type" => exception.class.name,
        "value" => @scrubber.scrub_message(exception.message),
        "stacktrace" => { "frames" => frames(exception.backtrace_locations) },
        "mechanism" => { "type" => "ruby", "handled" => @handled }
      }
    end

    # Sentry-style: most recent frame last; keys filename/function/lineno/in_app/abs_path
    # + source snippet (pre_context/context_line/post_context) when the file is readable.
    # `filename` is relative/basename (culprit comparable across SDKs — CYRB-4); `abs_path` is the
    # absolute path for the detail view and for reading the context lines' source.
    def frames(locations)
      return [] if locations.nil?

      context_lines = @configuration.context_lines.to_i
      locations.reverse.map do |loc|
        frame = {
          "filename" => relative_filename(loc.path),
          "abs_path" => loc.path,
          "function" => loc.label,
          "lineno" => loc.lineno,
          "in_app" => in_app?(loc.path)
        }
        add_context!(frame, loc.path, loc.lineno, context_lines) if context_lines.positive?
        frame
      end
    end

    # Path to display (Sentry `filename`): relative to project_root if the file is inside the app
    # (e.g. "app/models/user.rb"), otherwise the basename (gem/stdlib/external paths → "base.rb").
    # Aligns Ruby with the other SDKs (Dart/JS send basename/relative), so the culprit
    # "filename in function" is comparable at a glance on polyglot projects. See CYRB-4.
    def relative_filename(path)
      return path if path.nil?

      root = @configuration.project_root.to_s
      prefix = root.empty? ? nil : File.join(root, "") # root with trailing separator, portable
      return File.basename(path) unless prefix && path.start_with?(prefix)

      relative = path[prefix.length..]
      relative.nil? || relative.empty? ? File.basename(path) : relative
    end

    def add_context!(frame, path, lineno, count)
      lines = LineCache.lines(path)
      return if lines.nil? || lineno.nil? || lineno < 1 || lineno > lines.size

      index = lineno - 1
      frame["pre_context"]  = lines[[ index - count, 0 ].max...index]
      frame["context_line"] = lines[index]
      frame["post_context"] = lines[index + 1, count] || []
    end

    def in_app?(path)
      return false if path.nil?

      !path.include?("/gems/") && !path.include?(RbConfig::CONFIG["rubylibdir"].to_s)
    end
  end
end
