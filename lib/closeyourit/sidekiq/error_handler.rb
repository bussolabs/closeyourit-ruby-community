# frozen_string_literal: true

module CloseYourIt
  module Sidekiq
    # Sidekiq error handler (registered by the railtie only when Sidekiq is present). Sidekiq calls
    # `call(exception, context, config)` and does NOT re-raise → here we just capture.
    class ErrorHandler
      def call(exception, context, _config = nil)
        apply_job_scope(context)
        CloseYourIt.capture_exception(exception, handled: false)
      ensure
        CloseYourIt::Scope.reset!
      end

      private

      def apply_job_scope(context)
        job = (context && context[:job]) || {}
        CloseYourIt.set_tag("job.class", job["class"]) if job["class"]
        CloseYourIt.set_tag("job.queue", job["queue"]) if job["queue"]
        CloseYourIt.set_context("sidekiq", { "jid" => job["jid"] }) if job["jid"]
      end
    end
  end
end
