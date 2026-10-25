# frozen_string_literal: true

module CloseYourIt
  module Rails
    # `ActiveSupport::ErrorReporter` subscriber (Rails 7+): captures HANDLED errors reported via
    # `Rails.error.report`/`Rails.error.handle`. Unhandled ones already go through the Rack
    # middleware → dedup (ivar on the instance) avoids double sending.
    class ErrorSubscriber
      SEVERITY_TO_LEVEL = { error: "error", warning: "warning", info: "info" }.freeze

      # Noisy internal sources not to forward (avoids loops/duplicates).
      IGNORED_SOURCES = %w[closeyourit].freeze

      def report(error, handled:, severity:, context:, source: nil)
        return if source && IGNORED_SOURCES.include?(source)
        return unless CloseYourIt.configuration.capture_handled_errors

        level = SEVERITY_TO_LEVEL.fetch(severity, "error")
        contexts = context && !context.empty? ? { "rails_error" => stringify(context) } : nil
        CloseYourIt.capture_exception(error, handled: handled, level: level, contexts: contexts)
      end

      private

      def stringify(context)
        context.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
      end
    end
  end
end
