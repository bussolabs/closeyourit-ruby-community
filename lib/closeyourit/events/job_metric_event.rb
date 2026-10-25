# frozen_string_literal: true

require "securerandom"
require_relative "../event"

module CloseYourIt
  # `kind=performance_issue` metric for a background job that exceeded a DURATION threshold
  # (`subtype=slow_job`) or a queue WAIT threshold (`subtype=job_queue_latency`). Sent on the metrics
  # pipeline (`/api/v1/projects/:id/metrics`), like slow_query/slow_method and performance verdicts.
  #
  # `label` is the job CLASS name — never the arguments (privacy: like slow_method it sends only
  # label/duration). `attempt` makes retries visible; `trace_id` (= ActiveJob job_id / Sidekiq jid)
  # correlates the metric with logs and errors of the same job. `duration_ms` is the subtype's
  # measured value (perform duration for slow_job, queue wait for job_queue_latency) — same
  # convention as the Rollup. Nil fields are omitted.
  class JobMetricEvent < Event
    def initialize(attrs, configuration)
      super(configuration)
      @attrs = attrs
    end

    def to_h
      compact(
        "kind" => "performance_issue",
        "subtype" => @attrs[:subtype],
        "sample_id" => SecureRandom.uuid,
        "duration_ms" => @attrs[:duration_ms]&.round(2),
        "occurred_at" => @occurred_at,
        "environment" => environment,
        "release" => @configuration.release,
        "trace_id" => @attrs[:trace_id],
        "label" => @attrs[:job_class],
        "queue" => @attrs[:queue],
        "adapter" => @attrs[:adapter],
        "attempt" => @attrs[:attempt],
        "contexts" => (@attrs[:job_context] && { "job" => @attrs[:job_context].merge(
          "measurement" => (@attrs[:subtype] == "slow_job" ? "duration" : "queue_wait")
        ) }),
        "sdk" => sdk
      )
    end

    def ingest_path(project_id)
      "/api/v1/projects/#{project_id}/metrics"
    end
  end
end
