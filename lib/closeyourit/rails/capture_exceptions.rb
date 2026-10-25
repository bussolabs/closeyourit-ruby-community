# frozen_string_literal: true

module CloseYourIt
  module Rails
    # Rack middleware: captures unhandled exceptions, sends them to CloseYourIt
    # and **re-raises** them (the app keeps handling them as before). Pure Rack, no
    # Rails dependency → testable in isolation.
    class CaptureExceptions
      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      rescue Exception => e # rubocop:disable Lint/RescueException
        CloseYourIt.capture_exception(e)
        raise
      end
    end
  end
end
