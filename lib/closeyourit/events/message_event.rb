# frozen_string_literal: true

require "securerandom"
require_relative "../scrubber"

module CloseYourIt
  # Explicit diagnostic message (`CloseYourIt.capture_message`) in Sentry event format
  # (`message.formatted` + level). Merges the current Scope like ErrorEvent. The message goes through
  # the Scrubber (patterns) like ErrorEvent's `exception.message` — PII parity across events.
  class MessageEvent < Event
    def initialize(message, level:, configuration:)
      super(configuration)
      @message = message
      @level = level
      @scrubber = Scrubber.new(configuration)
    end

    def to_h
      base = compact(
        "event_id" => SecureRandom.uuid.delete("-"),
        "timestamp" => @occurred_at,
        "platform" => "ruby",
        "level" => @level,
        # Log↔error correlation: same trace_id as the logs of the same request (parity with ErrorEvent).
        "trace_id" => CloseYourIt::Scope.current.trace_id,
        "environment" => environment,
        "release" => @configuration.release,
        "server_name" => server_name,
        "message" => { "formatted" => @scrubber.scrub_message(@message.to_s) },
        "contexts" => { "runtime" => { "name" => "ruby", "version" => RUBY_VERSION } },
        "sdk" => sdk
      )
      deep_merge(base, CloseYourIt::Scope.current.to_event_hash)
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/events"
    end
  end
end
