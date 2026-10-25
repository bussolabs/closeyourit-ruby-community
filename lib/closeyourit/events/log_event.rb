# frozen_string_literal: true

require "securerandom"
require_relative "../scrubber"

module CloseYourIt
  # Structured log entry sent to the /logs ingest (NOT Sentry format: logs are a stream with
  # message/level/attributes/logger). `message` AND `attributes` go through the Scrubber (denylist +
  # patterns) like ErrorEvent — a log can contain as much PII/secrets as an error. `trace_id` is
  # frozen at CONSTRUCTION (request thread) → log↔error correlation for the same request even when
  # the flush happens on a different timer thread.
  class LogEvent < Event
    # Backend canonical levels (enum) + aliases of ::Logger-style names. Normalized HERE (single
    # source) so every construction — via CloseYourIt.log, .logger or directly — yields a valid level.
    # The index in LEVELS is also the level's numeric severity (debug=0 … fatal=4): the SAME map as
    # dart/js, so threshold gating (`logs_min_level`) filters identically across SDKs (CYRB-6).
    LEVELS = %w[debug info warning error fatal].freeze
    LEVEL_ALIASES = { "warn" => "warning", "err" => "error", "unknown" => "fatal" }.freeze

    # Normalizes any level (symbol/string, uppercase, alias) to the backend canonical name.
    # Unknown → "info". Class method: single source reused by `CloseYourIt.log` for gating.
    def self.normalize_level(level)
      value = level.to_s.downcase
      value = LEVEL_ALIASES.fetch(value, value)
      LEVELS.include?(value) ? value : "info"
    end

    # Numeric severity of the level (index in LEVELS), identical to the cross-SDK map. Used for the
    # comparison with `logs_min_level` before building/sending the log.
    def self.severity(level)
      LEVELS.index(normalize_level(level))
    end

    def initialize(message, level:, attributes:, configuration:, logger: nil)
      super(configuration)
      @message = message
      @level = self.class.normalize_level(level)
      @attributes = attributes || {}
      @logger = logger
      @scrubber = Scrubber.new(configuration)
      # trace_id captured HERE, on the request thread: the LogEvent is buffered and flushed on a
      # different timer thread, where the current Scope belongs to ANOTHER request (or is empty) →
      # reading it lazily in to_h would break log↔error correlation. We freeze it at construction.
      @trace_id = CloseYourIt::Scope.current.trace_id
    end

    def to_h
      compact(
        "event_id" => SecureRandom.uuid.delete("-"),
        "timestamp" => @occurred_at,
        "level" => @level,
        "message" => @scrubber.scrub_message(@message.to_s),
        "attributes" => scrubbed_attributes,
        "logger" => @logger,
        "trace_id" => @trace_id,
        "environment" => environment,
        "release" => @configuration.release,
        "sdk" => sdk
      )
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/logs"
    end

    private

    def scrubbed_attributes
      return {} if @attributes.nil? || @attributes.empty?

      @scrubber.filter_params(deep_stringify_keys(@attributes))
    end

    # Keys always strings (nested too): consistent with the JSON payload and the Scrubber denylist.
    def deep_stringify_keys(value)
      case value
      when Hash  then value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = deep_stringify_keys(val) }
      when Array then value.map { |item| deep_stringify_keys(item) }
      else value
      end
    end
  end
end
