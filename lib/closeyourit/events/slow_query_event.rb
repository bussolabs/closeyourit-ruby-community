# frozen_string_literal: true

require "securerandom"
require_relative "../event"
require_relative "../scrubber"
require_relative "../scope"

module CloseYourIt
  # `kind=slow_query` payload for the metrics pipeline (`/api/v1/projects/:id/metrics`).
  # The SQL is obfuscated (binds excluded) — see PDR §9.
  class SlowQueryEvent < Event
    def initialize(payload, duration_ms, configuration)
      super(configuration)
      @payload = payload
      @duration_ms = duration_ms
      @scrubber = Scrubber.new(configuration)
    end

    def to_h
      compact(
        "kind" => "slow_query",
        "sample_id" => SecureRandom.uuid,
        "duration_ms" => @duration_ms.round(2),
        "occurred_at" => @occurred_at,
        "environment" => environment,
        "sql" => @scrubber.obfuscate_sql(@payload[:sql]),
        "name" => @payload[:name],
        "cached" => @payload.fetch(:cached, false),
        "db_system" => db_system,
        "source" => @payload[:source],
        "trace_id" => CloseYourIt::Scope.current.trace_id,
        "bindings" => bindings,
        "sdk" => sdk
      )
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/metrics"
    end

    private

    def db_system
      connection = @payload[:connection]
      return nil unless connection.respond_to?(:adapter_name)

      connection.adapter_name.to_s.downcase
    end

    # Bind values — ONLY with capture_query_bindings (opt-in, default OFF). Scrubbed by column name
    # (denylist password/token/…); the value is rendered as a string for JSON safety.
    def bindings
      return nil unless @configuration.capture_query_bindings

      binds = Array(@payload[:binds])
      values = Array(@payload[:type_casted_binds])
      binds.each_with_index.map do |attr, i|
        name = attr.respond_to?(:name) ? attr.name.to_s : attr.to_s
        { "name" => name, "value" => @scrubber.filter_value(name, values[i]).to_s }
      end
    end
  end
end
