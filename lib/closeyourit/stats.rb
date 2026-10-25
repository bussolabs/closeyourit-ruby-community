# frozen_string_literal: true

require "concurrent"

module CloseYourIt
  # Thread-safe client diagnostic counters: how many events were enqueued, dropped (full queue /
  # before_send / sampling), sent successfully, failed (network or non-2xx status) and, among the
  # failed, how many by network timeout. They make the silent failures of the fire-and-forget
  # transport visible. `timeout` is a sub-count of `failed` (a timeout is still a send failure):
  # we keep them apart to isolate connectivity problems from non-2xx.
  #
  #   CloseYourIt.stats.to_h # => { enqueued: 12, dropped: 0, sent: 11, failed: 1, timeout: 1 }
  class Stats
    COUNTERS = %i[enqueued dropped sent failed timeout].freeze

    def initialize
      @counters = COUNTERS.to_h { |name| [ name, Concurrent::AtomicFixnum.new(0) ] }
    end

    def increment(name)
      counter = @counters.fetch(name)
      counter.increment
      counter.value
    end

    def [](name)
      @counters.fetch(name).value
    end

    def to_h
      @counters.transform_values(&:value)
    end

    # Thread-safe snapshot of the counters (each value read atomically). It is the same Hash as
    # `to_h`, with an explicit name for the "read the local diagnostics" use case (CYRB-12): a pure
    # in-memory read, it never sends telemetry.
    alias_method :snapshot, :to_h

    def reset!
      @counters.each_value { |counter| counter.value = 0 }
      self
    end
  end
end
