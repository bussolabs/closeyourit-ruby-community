# frozen_string_literal: true

require_relative "events/slow_method_event"

module CloseYourIt
  # Times blocks/methods with `CLOCK_MONOTONIC` and sends a `slow_method` when the duration exceeds
  # the threshold. Arguments are sent only with `capture_method_arguments` (opt-in) — see SlowMethodEvent.
  module Instrumenter
    module_function

    def measure(label, args: nil, kwargs: nil)
      location = caller_locations(1, 1)&.first
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
    ensure
      # `measure` runs INSIDE the app's method (Monitor prepends): a failure here — threshold not
      # configured, unreachable ingest — would raise in a caller that already had its result. It was
      # the only unguarded entry point of the gem: now it is like all the others (CYRB-24). An
      # exception from the measured block, instead, keeps propagating untouched.
      begin
        duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0
        report(label, duration_ms, location, args: args, kwargs: kwargs)
      rescue StandardError => e
        CloseYourIt.internal_logger.error("CloseYourIt instrumenter: #{e.class}: #{e.message}")
      end
    end

    def report(label, duration_ms, location = nil, args: nil, kwargs: nil)
      config = CloseYourIt.configuration
      return if duration_ms < config.slow_method_threshold_ms

      CloseYourIt.capture_event(
        SlowMethodEvent.new(label, duration_ms, location, config, args: args, kwargs: kwargs)
      )
    end
  end
end
