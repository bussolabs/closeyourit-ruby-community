# frozen_string_literal: true

require "securerandom"

module CloseYourIt
  # W3C trace context (`traceparent`/`tracestate`, https://www.w3.org/TR/trace-context/).
  # It is NOT a tracer: it opens no spans and measures no times. It is a minimal "propagation bridge"
  # (the ticket: "do not build full custom tracing") — it adopts a valid incoming context passing
  # through trace-id/parent-id/flags, or generates a root one, and serializes into outgoing headers.
  # Deliberately separate from proprietary formats: standard-based, with no vendor dependency.
  class TraceContext
    # traceparent = version "-" trace-id "-" parent-id "-" trace-flags (55 chars for version 00).
    # `rest` captures any future fields: allowed only for versions > 00 (forward-compat), forbidden on 00.
    TRACEPARENT = /
      \A
      (?<version>[0-9a-f]{2})-
      (?<trace_id>[0-9a-f]{32})-
      (?<parent_id>[0-9a-f]{16})-
      (?<flags>[0-9a-f]{2})
      (?<rest>-.*)?
      \z
    /x

    FORBIDDEN_VERSION = "ff"
    CURRENT_VERSION   = "00"
    ZERO_TRACE_ID     = ("0" * 32).freeze
    ZERO_PARENT_ID    = ("0" * 16).freeze
    FLAG_SAMPLED      = 0x01

    # tracestate: comma-separated list of `key=value` members, max 32 (W3C §3.3.1).
    TRACESTATE_MAX_MEMBERS = 32
    # key: leading lowercase alnum + restricted set (including `@`/`/` for tenant@vendor keys).
    # value: printable characters 0x20–0x7E except `,` (0x2C) and `=` (0x3D).
    TRACESTATE_MEMBER = %r{\A[a-z0-9][a-z0-9_\-*/@]*=[\x20-\x2b\x2d-\x3c\x3e-\x7e]+\z}

    attr_reader :trace_id, :parent_id, :flags, :tracestate

    def initialize(trace_id:, parent_id:, flags:, tracestate: nil)
      @trace_id   = trace_id
      @parent_id  = parent_id
      @flags      = flags
      @tracestate = tracestate
    end

    class << self
      # Adopts an incoming traceparent. Returns nil when malformed (→ the caller generates a root or
      # leaves the context absent). Pass-through: keeps trace-id/parent-id/flags verbatim so the
      # bridge invents no spans. The tracestate is sanitized (invalid members dropped, capped at 32).
      def parse(traceparent, tracestate = nil)
        match = TRACEPARENT.match(traceparent.to_s.strip)
        return nil unless match
        return nil if match[:version] == FORBIDDEN_VERSION
        return nil if match[:version] == CURRENT_VERSION && match[:rest]
        return nil if match[:trace_id] == ZERO_TRACE_ID
        return nil if match[:parent_id] == ZERO_PARENT_ID

        new(
          trace_id:   match[:trace_id],
          parent_id:  match[:parent_id],
          flags:      match[:flags].to_i(16),
          tracestate: sanitize_tracestate(tracestate)
        )
      end

      # New root context (no valid incoming traceparent). Generates random trace-id (16 bytes) and
      # parent-id (8 bytes) — SecureRandom is fork-safe, so a forked worker does not reuse the parent's
      # ids. `sampled` sets the flag: a root we open traces by default.
      def generate(sampled: true)
        new(
          trace_id:   SecureRandom.hex(16),
          parent_id:  SecureRandom.hex(8),
          flags:      sampled ? FLAG_SAMPLED : 0,
          tracestate: nil
        )
      end

      private

      # Keeps only well-formed members, in the original order, up to 32. Returns nil if none are left
      # → so we never propagate a garbage or oversized tracestate.
      def sanitize_tracestate(tracestate)
        return nil if tracestate.nil?

        valid = tracestate.to_s.split(",").map(&:strip)
                          .select { |member| TRACESTATE_MEMBER.match?(member) }
                          .first(TRACESTATE_MAX_MEMBERS)
        valid.empty? ? nil : valid.join(",")
      end
    end

    def sampled?
      (flags & FLAG_SAMPLED) != 0
    end

    # Outgoing traceparent, always version 00 (the only one we can emit). Flags are re-emitted in full
    # (reserved bits must be propagated as-is), formatted as two hex digits.
    def traceparent
      format("%s-%s-%s-%02x", CURRENT_VERSION, trace_id, parent_id, flags & 0xff)
    end

    # W3C propagation headers: traceparent (+ tracestate if present). NEVER `baggage`: it may carry
    # internal context/PII and must not cross the boundary (ticket: "sensitive baggage gets no header").
    def headers
      result = { "traceparent" => traceparent }
      result["tracestate"] = tracestate if tracestate && !tracestate.empty?
      result
    end
  end
end
