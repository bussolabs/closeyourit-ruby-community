# frozen_string_literal: true

module CloseYourIt
  module Rails
    # Included in ActiveJob::Base (via the railtie's `on_load(:active_job)`): captures job errors
    # (otherwise lost) with the job context. The logic lives in `.monitor`/`.report_discarded` so it
    # is testable without ActiveSupport/ActiveJob.
    #
    # CYRB-19: `around_perform` runs INSIDE `perform_now`, while `retry_on`/`discard_on` (rescue_from)
    # are evaluated OUTSIDE, after the callbacks. Capturing in around_perform therefore means reporting
    # EVERY attempt — even those that will be retried successfully — because the reporter sees the
    # error before the retry can silence it, and every attempt raises a new instance (the internal,
    # per-instance dedup does not kick in). On ActiveJob 7.1+ we delegate reporting to `after_discard`,
    # which Rails calls on final failure (retry_on exhausted or unhandled exception), never on the
    # attempts `retry_on` retries → a single occurrence per job.
    #
    # Known limits (by ActiveJob's design, not the client's):
    # - `after_discard` does NOT fire for errors caught by a custom `rescue_from`: they are handled by
    #   the app, so we no longer report them as "unhandled" (we used to, improperly).
    # - ADAPTER-level retries (e.g. Sidekiq) WITHOUT `retry_on` re-raise the unhandled error:
    #   `after_discard` fires on every execution, so per-attempt dedup does not apply there
    #   (behavior unchanged from before).
    # On versions without `after_discard` we keep the legacy fallback (capture in around_perform).
    module ActiveJobExtension
      # Scope enriched during `perform`, handed over to `after_discard`. Bound to the job INSTANCE
      # (every retry creates a new, deserialized one) → it lives exactly as long as needed, no bleed
      # between jobs or threads; the end-of-`perform` reset only detaches it from storage, it does not
      # mutate the object.
      STASHED_SCOPE_IVAR = :@__closeyourit_stashed_scope

      def self.included(base)
        base.around_perform do |job, block|
          CloseYourIt::Rails::ActiveJobExtension.monitor(job) { block.call }
        rescue Exception # rubocop:disable Lint/RescueException
          job.instance_variable_set(:@__closeyourit_job_outcome, :raised)
          raise
        end

        return unless base.respond_to?(:after_discard)

        base.after_discard do |job, exception|
          CloseYourIt::Rails::ActiveJobExtension.report_discarded(job, exception)
        end
      end

      # Runs the job enriching the scope with tags/context; resets the scope at the end of the job (no
      # bleed between jobs on the same thread). On ActiveJob 7.1+ it does NOT capture the error
      # (`after_discard` does, only on final failure): here it hands the scope to the job and re-raises.
      # On the legacy fallback it captures.
      def self.monitor(job)
        return yield unless CloseYourIt.configuration.report_active_job_errors

        begin
          apply_job_scope(job)
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          if report_on_discard?(job)
            job.instance_variable_set(STASHED_SCOPE_IVAR, CloseYourIt::Scope.current)
          else
            CloseYourIt.capture_exception(e, handled: false)
          end
          raise
        ensure
          CloseYourIt::Scope.reset!
        end
      end

      # `after_discard` hook (ActiveJob 7.1+): the job has failed for good, so we report the error ONLY
      # once (handled:false). We restore the scope enriched during `perform` (handed over by `monitor`)
      # so the report keeps the breadcrumbs/tags/contexts collected in the job; `apply_job_scope`
      # refreshes the standard fields with the final `executions` without losing the custom ones.
      def self.report_discarded(job, exception)
        return unless CloseYourIt.configuration.report_active_job_errors

        begin
          stashed = job.instance_variable_get(STASHED_SCOPE_IVAR)
          CloseYourIt::Scope.current = stashed if stashed
          apply_job_scope(job)
          CloseYourIt.capture_exception(exception, handled: false)
        ensure
          job.remove_instance_variable(STASHED_SCOPE_IVAR) if job.instance_variable_defined?(STASHED_SCOPE_IVAR)
          CloseYourIt::Scope.reset!
        end
      end

      # true when ActiveJob exposes `after_discard` (7.1+): reporting is delegated there, so `monitor`
      # does not capture intermediate attempts. false → legacy fallback (capture in around_perform).
      def self.report_on_discard?(job)
        job.class.respond_to?(:after_discard)
      end

      def self.apply_job_scope(job)
        CloseYourIt.set_tag("job.class", job.class.name)
        CloseYourIt.set_tag("job.queue", job.queue_name) if job.respond_to?(:queue_name)

        context = {}
        context["job_id"] = job.job_id if job.respond_to?(:job_id)
        context["executions"] = job.executions if job.respond_to?(:executions)
        CloseYourIt.set_context("active_job", context) unless context.empty?

        # A stable trace_id per execution (job_id is unique per ActiveJob run): logs and error of the
        # same job share the trace_id → log↔error correlation outside the request cycle too.
        CloseYourIt::Scope.current.trace_id = job.job_id if job.respond_to?(:job_id)
      end
    end
  end
end
