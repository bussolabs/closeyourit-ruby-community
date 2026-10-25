# frozen_string_literal: true

require_relative "capture_exceptions"
require_relative "request_context"
require_relative "active_job_extension"
require_relative "error_subscriber"
require_relative "../sidekiq/error_handler"
require_relative "query_source"
require_relative "log_broadcast"
require_relative "net_http_patch"
require_relative "../subscribers/slow_query"
require_relative "../subscribers/request_performance"
require_relative "../subscribers/job_performance"
require_relative "../sidekiq/job_metrics_middleware"

module CloseYourIt
  module Rails
    # Hooks the client into Rails: exception-capturing Rack middleware +
    # `sql.active_record` subscriber for slow queries.
    class Railtie < ::Rails::Railtie
      initializer "closeyourit.use_rack_middleware" do |app|
        app.config.middleware.use CloseYourIt::Rails::CaptureExceptions
        # RequestContext must WRAP CaptureExceptions: the scope must already be populated
        # when the exception bubbles up to CaptureExceptions.
        app.config.middleware.insert_before(
          CloseYourIt::Rails::CaptureExceptions,
          CloseYourIt::Rails::RequestContext
        )
      end

      # Open Dashboard (GET /open-dashboard). Inside CaptureExceptions, so a crash while building the
      # report is reported like any other request error. Inert until the app calls
      # CloseYourIt::OpenDashboard.configure with a token.
      initializer "closeyourit.open_dashboard" do |app|
        app.config.middleware.insert_after(
          CloseYourIt::Rails::CaptureExceptions,
          CloseYourIt::OpenDashboard::Middleware
        )
      end

      initializer "closeyourit.subscribe_slow_queries" do
        subscriber = CloseYourIt::Subscribers::SlowQuery.new

        ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          # Slow query, breadcrumb and per-request profile (N+1 detection). The call site is lazy:
          # a backtrace for every query was the SDK's biggest cost on the host thread.
          subscriber.notify(event.payload, event.duration, -> { CloseYourIt::Rails::QuerySource.from_caller })
        end
      end

      # At the end of the request: turns the collected profile into performance_issue verdicts (N+1,
      # slow request, slow external HTTP). The subscriber is a no-op when detect_performance_issues is OFF.
      initializer "closeyourit.subscribe_request_performance" do
        perf = CloseYourIt::Subscribers::RequestPerformance.new

        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          payload = event.payload
          # CYSK-29 — usage telemetry: the route is `Controller#action`, NEVER the URL. The registry does
          # one lookup and one increment; the usage_enabled gate lives inside #record.
          CloseYourIt.usage_registry.record("route", "#{payload[:controller]}##{payload[:action]}") if CloseYourIt.enabled?
          perf.record(
            route: "#{payload[:controller]}##{payload[:action]}",
            duration_ms: event.duration
          )
        end
      end

      # Instruments Net::HTTP: detects slow external calls (only with detect_performance_issues) and
      # propagates the W3C trace context (only with propagate_trace_context). Unconditional prepend —
      # the two opt-ins are evaluated per call in the patch; with both OFF it is in effect a no-op (calls super).
      initializer "closeyourit.instrument_net_http" do
        require "net/http"
        ::Net::HTTP.prepend(CloseYourIt::Rails::NetHTTPPatch) unless ::Net::HTTP.ancestors.include?(CloseYourIt::Rails::NetHTTPPatch)
      end

      # Captures ActiveJob/Solid Queue errors (around_perform).
      initializer "closeyourit.active_job" do
        ActiveSupport.on_load(:active_job) do
          include CloseYourIt::Rails::ActiveJobExtension
        end
      end

      # Observe the completed attempt after ActiveJob has decided retry/discard.
      initializer "closeyourit.subscribe_active_job_performance" do
        CloseYourIt::Subscribers::JobPerformance.new.install
      end

      # Captures HANDLED errors reported via Rails.error.report (Rails 7+).
      initializer "closeyourit.error_reporter" do
        if ::Rails.respond_to?(:error) && ::Rails.error.respond_to?(:subscribe)
          ::Rails.error.subscribe(CloseYourIt::Rails::ErrorSubscriber.new)
        end
      end

      # Opt-in Rails.logger → CloseYourIt.log broadcast (config.capture_rails_logs, default OFF).
      # Sends only app logs ≥ capture_rails_logs_min_level: a DEDICATED threshold (default :warn),
      # separate from logs_min_level, so the broadcast does not flood the stream with framework info
      # noise (Started GET, Rendered, ... — one line per request under high traffic, CYRB-7). Requires
      # BroadcastLogger (Rails 7.1+).
      # `after: :load_config_initializers`: config.capture_rails_logs is set in
      # config/initializers/closeyourit.rb (CloseYourIt.init), which runs AFTER the railtie
      # initializers. Without this `after:` the check would read the default (false) and the broadcast
      # would never be attached → the app logs would never reach CloseYourIt.
      initializer "closeyourit.capture_rails_logs", after: :load_config_initializers do
        config = CloseYourIt.configuration
        if config.capture_rails_logs && ::Rails.logger.respond_to?(:broadcast_to)
          ::Rails.logger.broadcast_to(CloseYourIt::Rails::LogBroadcast.new(config.capture_rails_logs_min_level))
        end
      end

      # Keys the app declared sensitive via config.filter_parameters are scrubbed by the gem too.
      # `after: :load_config_initializers`: CloseYourIt.init (config/initializers/closeyourit.rb)
      # replaces the configuration, so an earlier merge would be lost (CYRB-28).
      initializer "closeyourit.merge_rails_filter_parameters", after: :load_config_initializers do |app|
        CloseYourIt.configuration.merge_filter_parameters(app.config.filter_parameters)
      end

      # Captures Sidekiq job errors + measures duration/wait via server middleware (only when Sidekiq
      # is present). The middleware is effectively a no-op when monitor_jobs is OFF (the decision
      # lives in JobPerformance#record).
      initializer "closeyourit.sidekiq" do
        if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)
          ::Sidekiq.configure_server do |sidekiq_config|
            sidekiq_config.error_handlers << CloseYourIt::Sidekiq::ErrorHandler.new
            sidekiq_config.server_middleware do |chain|
              chain.add CloseYourIt::Sidekiq::JobMetricsMiddleware
            end
          end
        end
      end
    end
  end
end
