# frozen_string_literal: true

require "time"
require "date"

module CloseYourIt
  # Versioned attempt metadata. Missing clocks stay unknown, never an invented zero.
  module JobContext
    def self.build(framework:, name:, queue: nil, job_id: nil, attempt: nil, retry_count: :derive,
                   enqueued_at: nil, scheduled_at: nil, started_at: nil)
      enqueued, scheduled, started = [ enqueued_at, scheduled_at, started_at ].map { |value| instant(value) }
      due = enqueued && scheduled ? [ enqueued, scheduled ].max : enqueued
      wait = (started - due) * 1000.0 if started && due
      delay = (scheduled - enqueued) * 1000.0 if enqueued && scheduled
      attempt = nil unless attempt.is_a?(Integer) && attempt.positive?
      retry_count = attempt && attempt - 1 if retry_count == :derive
      retry_count = nil unless retry_count.is_a?(Integer) && retry_count >= 0
      {
        "schema_version" => 1, "framework" => framework, "name" => bounded_text(name, 200) || "unknown",
        "queue" => bounded_text(queue, 128), "job_id" => bounded_text(job_id, 256), "attempt" => attempt,
        "retry_count" => retry_count, "attempt_outcome" => "unknown", "terminal" => nil,
        "enqueued_at" => enqueued&.iso8601(6), "scheduled_at" => scheduled&.iso8601(6),
        "started_at" => started&.iso8601(6), "duration_ms" => nil,
        "queue_wait_ms" => wait && [ wait, 0.0 ].max,
        "scheduled_delay_ms" => delay && [ delay, 0.0 ].max, "clock_skew" => !!(wait && wait.negative?)
      }
    end

    def self.bounded_text(value, limit)
      value if value.is_a?(String) && value.length.between?(1, limit) && !value.match?(/[\x00-\x1f\x7f]/)
    end

    def self.sidekiq_time(value, version:)
      return value unless value.is_a?(Numeric)

      version.to_s.split(".").first.to_i >= 8 ? value / 1000.0 : value
    end

    def self.instant(value)
      case value
      when Time then value.getutc
      when Numeric then Time.at(value).utc if value.finite?
      when String
        if value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
          DateTime.rfc3339(value)
          Time.iso8601(value).utc
        end
      end
    rescue ArgumentError, RangeError
      nil
    end

    def self.log(context, configuration)
      return unless configuration.monitor_jobs && configuration.job_lifecycle_logs

      CloseYourIt.log(:info, "Background job attempt finished", logger: "closeyourit.jobs", contexts: { job: context })
    rescue StandardError
      CloseYourIt.internal_logger.warn("CloseYourIt job lifecycle emission failed")
    end
  end
end
