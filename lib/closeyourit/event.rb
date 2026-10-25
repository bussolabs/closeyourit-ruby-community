# frozen_string_literal: true

require "time"
require "socket"

module CloseYourIt
  # Base of telemetry events. Subclasses implement `#to_h` and `#ingest_path`
  # (the API path the event is sent to: errors → /events, metrics → /metrics).
  class Event
    def initialize(configuration)
      @configuration = configuration
      @occurred_at = Time.now.utc.iso8601
    end

    def to_h
      raise NotImplementedError, "#{self.class} must implement #to_h"
    end

    def ingest_path(_project_id)
      raise NotImplementedError, "#{self.class} must implement #ingest_path"
    end

    private

    def environment
      @configuration.environment
    end

    def sdk
      { "name" => "closeyourit-ruby", "version" => VERSION }
    end

    def server_name
      return nil unless @configuration.send_server_name

      Socket.gethostname
    rescue StandardError
      nil
    end

    def compact(hash)
      hash.reject { |_key, value| value.nil? }
    end

    # Recursive merge: nested Hashes are merged (e.g. `contexts.runtime` kept while the scope adds
    # `contexts.active_job`), scalars are overwritten.
    def deep_merge(base, override)
      base.merge(override) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end
  end
end
