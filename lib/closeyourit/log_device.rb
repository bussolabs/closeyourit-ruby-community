# frozen_string_literal: true

module CloseYourIt
  # Logger-compatible object exposed as `CloseYourIt.logger`: every call forwards to
  # `CloseYourIt.emit_log` (→ ingest /logs). Usable as the app's explicit logger, also with attributes:
  #   CloseYourIt.logger.warn("disk almost full", disk: "sda1")
  # `warn` maps to the `warning` level (backend enum); supports blocks and `::Logger#add` as a drop-in.
  #
  # The log source (the payload's `logger` field) is set ONLY via `.named` (child logger, dart/js
  # parity) or the constructor — NEVER from a method keyword: so a `logger` key passed to a method
  # stays a data attribute and is not hijacked as the source (CYRB-8).
  #   payments = CloseYourIt.logger.named("payments") # child with source "payments"
  #   payments.warn("retry", attempt: 3)              # logger=payments, attributes={attempt:3}
  #   CloseYourIt.logger.warn("disk full", logger: "/dev/sda1") # attributes={logger:"/dev/sda1"}
  class LogDevice
    # ::Logger numeric severities → CloseYourIt levels (UNKNOWN→fatal).
    SEVERITY_LEVELS = { 0 => "debug", 1 => "info", 2 => "warning", 3 => "error", 4 => "fatal", 5 => "fatal" }.freeze

    # `source` = name of the log source (the payload's `logger` field). Prefer `.named` in apps.
    def initialize(source = nil)
      @source = normalize_source(source)
    end

    # Child logger with an explicit source (dart/js parity). Returns a NEW LogDevice: the logger it is
    # called on stays unchanged (immutable), like the cross-SDK child loggers.
    #   CloseYourIt.logger.named("payments").info("retry", attempt: 3)
    def named(source)
      self.class.new(source)
    end

    def debug(message = nil, **attributes, &block) = write("debug", message, attributes, &block)
    def info(message = nil, **attributes, &block)  = write("info", message, attributes, &block)
    def warn(message = nil, **attributes, &block)  = write("warning", message, attributes, &block)
    def error(message = nil, **attributes, &block) = write("error", message, attributes, &block)
    def fatal(message = nil, **attributes, &block) = write("fatal", message, attributes, &block)

    def <<(message)
      write("info", message, {})
      message
    end

    # Compatible with ::Logger#add(severity, message = nil, progname = nil).
    def add(severity, message = nil, progname = nil, &block)
      write(SEVERITY_LEVELS.fetch(severity.to_i, "info"), message || progname, {}, &block)
    end
    alias log add

    private

    def write(level, message, attributes, &block)
      # Gate BEFORE the block: `logger.debug { expensive_dump }` does not evaluate the block when logs are off.
      return unless CloseYourIt.logs_active?

      message = block.call if block
      # Source and attributes kept apart: the `attributes` (including any `logger` key) stay data;
      # the source is ONLY `@source` (via `.named`/constructor) → no collision (CYRB-8).
      CloseYourIt.emit_log(level, message, source: @source, attributes: attributes)
    end

    # Empty/blank source → no source (nil); otherwise a string (the `logger` field is textual).
    def normalize_source(source)
      return nil if source.nil?

      value = source.to_s.strip
      value.empty? ? nil : value
    end
  end
end
