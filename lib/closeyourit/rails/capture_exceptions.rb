# frozen_string_literal: true

module CloseYourIt
  module Rails
    # Rack middleware: captures unhandled exceptions, sends them to CloseYourIt
    # and lets them through (the app keeps handling them as before). Pure Rack, no
    # Rails dependency → testable in isolation.
    class CaptureExceptions
      def initialize(app)
        @app = app
      end

      # Captures in `ensure` instead of rescue + re-raise (CYRB-35): re-raising a frozen exception that
      # already has a backtrace makes Ruby raise an unfrozen COPY, so the app would get a different
      # instance than its own. From `ensure` the original keeps propagating untouched. `$!` at entry is
      # remembered so that a normal return or a `throw` made while an outer exception is being handled
      # (`$!` still pointing at it) is not mistaken for an error of this request.
      def call(env)
        outer_error = $!
        @app.call(env)
      ensure
        error = $!
        CloseYourIt.capture_exception(error) if error && !error.equal?(outer_error)
      end
    end
  end
end
