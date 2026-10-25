# frozen_string_literal: true

require "concurrent"

module CloseYourIt
  # CYSK-29 — usage telemetry: records WHICH symbols actually run (routes as `Controller#action`,
  # jobs, literal custom keys) and flushes them in one POST every `usage_flush_interval` seconds per
  # process. On the hot path: one lookup and one increment.
  #
  # The rules that make the system immune to losses:
  # - counts are INDICATIVE, only `last_seen_at` is load-bearing: a lost flush costs one window on a
  #   symbol that shows up again right after;
  # - the registry is EMPTIED on every flush: the cap (`usage_max_symbols`) limits the distinct
  #   symbols seen in one window — a quantity tied to traffic, not to code size;
  # - beyond the cap the flush carries `truncated: true`, and on the scanner side that flag
  #   DISQUALIFIES the kind;
  # - no sampling, ever: sampling a route called 3 times a month fabricates exactly the false
  #   "never seen" the system exists to avoid;
  # - `route` is `Controller#action`, NEVER the URL: no path, parameters, user, IP.
  class UsageRegistry
    # Symbols come from framework payloads or literal strings: the pattern is the contract.
    SYMBOL_FORMAT = %r{\A[A-Za-z0-9_:#./-]{1,200}\z}
    KINDS = %w[route job custom].freeze

    attr_reader :timer # exposed for tests (checks the configured interval)

    def initialize(client:, configuration:)
      @client = client
      @configuration = configuration
      @mutex = Mutex.new
      @symbols = {}
      @truncated = false
      @window_started_at = Time.now.utc
      @timer = nil
    end

    def record(kind, symbol)
      return unless @configuration.usage_enabled

      kind = kind.to_s
      symbol = symbol.to_s
      return unless KINDS.include?(kind) && symbol.match?(SYMBOL_FORMAT)

      @mutex.synchronize do
        key = [ kind, symbol ]
        entry = @symbols[key]
        if entry
          entry[:count] += 1
          entry[:last_seen_at] = Time.now.utc
        elsif @symbols.size >= @configuration.usage_max_symbols.to_i
          @truncated = true
        else
          @symbols[key] = { count: 1, last_seen_at: Time.now.utc }
        end
        ensure_timer
      end
    end

    def flush
      payload = drain
      return if payload[:symbols].empty? && !payload[:truncated]

      @client.flush_usage(**payload)
    rescue StandardError => e
      # The flush runs on the timer thread: an error must not propagate into the app nor kill the
      # TimerTask. The load-bearing semantics is last_seen_at: a lost window falsifies nothing.
      CloseYourIt.internal_logger.error("CloseYourIt usage registry: #{e.class}: #{e.message}")
    end

    def shutdown
      @timer&.shutdown
      flush
    end

    private

    def drain
      @mutex.synchronize do
        symbols = @symbols.map do |(kind, symbol), entry|
          { kind: kind, symbol: symbol, count: entry[:count], last_seen_at: entry[:last_seen_at].iso8601 }
        end
        payload = { symbols: symbols, truncated: @truncated,
                    window_started_at: @window_started_at.iso8601, window_ended_at: Time.now.utc.iso8601 }
        @symbols = {}
        @truncated = false
        @window_started_at = Time.now.utc
        payload
      end
    end

    def ensure_timer
      return if @timer

      interval = @configuration.usage_flush_interval.to_i
      interval = 300 if interval <= 0
      @timer = Concurrent::TimerTask.new(execution_interval: interval) { flush }
      @timer.execute
    end
  end
end
