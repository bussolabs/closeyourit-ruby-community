# frozen_string_literal: true

require "digest"
require "json"
require "openssl"

module CloseYourIt
  module OpenDashboard
    # Pure Rack: answers GET /open-dashboard and passes everything else to the app. Without a token
    # the request also goes to the app, so the route simply does not exist (404 from the app).
    class Middleware
      JSON_HEADERS = { "content-type" => "application/json", "cache-control" => "no-store" }.freeze
      BEARER = "Bearer "

      def initialize(app)
        @app = app
      end

      def call(env)
        settings = OpenDashboard.settings
        return @app.call(env) unless dashboard_request?(env) && settings&.enabled?
        return [ 401, { "cache-control" => "no-store" }, [] ] unless authorized?(env["HTTP_AUTHORIZATION"], settings.token)

        [ 200, JSON_HEADERS.dup, [ JSON.generate(Report.new(settings).to_h) ] ]
      end

      private

      def dashboard_request?(env)
        env["REQUEST_METHOD"] == "GET" && env["PATH_INFO"] == PATH
      end

      # Hashing both sides gives equal lengths, so the comparison time does not leak the token length.
      def authorized?(header, token)
        header = header.to_s
        return false unless header.start_with?(BEARER)

        OpenSSL.fixed_length_secure_compare(
          Digest::SHA256.digest(header.delete_prefix(BEARER)),
          Digest::SHA256.digest(token.to_s)
        )
      end
    end
  end
end
