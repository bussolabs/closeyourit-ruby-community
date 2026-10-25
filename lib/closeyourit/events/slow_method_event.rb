# frozen_string_literal: true

require "securerandom"
require_relative "../event"
require_relative "../scrubber"

module CloseYourIt
  # `kind=slow_method` payload for the metrics pipeline. By default only label + duration + location.
  # Method arguments are sent ONLY with `capture_method_arguments` (opt-in, default OFF):
  # positional by index, kwargs by name (sensitive key scrubbing), value via `inspect`
  # truncated for JSON safety. See PDR §9.
  class SlowMethodEvent < Event
    def initialize(label, duration_ms, location, configuration, args: nil, kwargs: nil)
      super(configuration)
      @label = label
      @duration_ms = duration_ms
      @location = location
      @args = args
      @kwargs = kwargs
      @scrubber = Scrubber.new(configuration)
    end

    def to_h
      compact(
        "kind" => "slow_method",
        "sample_id" => SecureRandom.uuid,
        "duration_ms" => @duration_ms.round(2),
        "occurred_at" => @occurred_at,
        "environment" => environment,
        "label" => @label,
        "file" => @location&.path,
        "lineno" => @location&.lineno,
        "arguments" => arguments,
        "sdk" => sdk
      )
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/metrics"
    end

    private

    # Arguments — ONLY with capture_method_arguments (opt-in). Positional by index; kwargs by name with
    # sensitive key scrubbing (denylist password/token/…). Value = truncated inspect (JSON-safe),
    # passed through the message scrubber (auth schemes + scrub_message_patterns) like exception
    # messages, so a token inside a positional argument never leaves the app (CYRB-28).
    def arguments
      return nil unless @configuration.capture_method_arguments

      list = Array(@args).each_with_index.map { |arg, i| { "name" => "arg#{i + 1}", "value" => safe_value(arg) } }
      (@kwargs || {}).each do |key, value|
        list << { "name" => key.to_s, "value" => @scrubber.filter_value(key, safe_value(value)) }
      end
      list
    end

    def safe_value(value)
      inspected = @scrubber.scrub_message(value.inspect.to_s)
      inspected.length > 120 ? "#{inspected[0, 117]}…" : inspected
    end
  end
end
