# frozen_string_literal: true

module CloseYourIt
  module OpenDashboard
    # What the service declares in config/initializers/open_dashboard.rb.
    class Settings
      LOCALE_FORMAT = /\A[a-z]{2}(-[A-Z]{2})?\z/

      attr_accessor :token, :name, :app, :url, :locale
      attr_reader :metrics

      def initialize
        @metrics = []
      end

      def metric(key, **options, &block)
        if @metrics.any? { |existing| existing.key == key.to_s }
          raise ConfigurationError, "open_dashboard metric #{key}: duplicated key"
        end

        @metrics << Metric.new(key, **options, &block)
      end

      # No token means the feature is off: the route does not exist.
      def enabled? = !token.to_s.strip.empty?

      def validate!
        %i[name app].each do |field|
          raise ConfigurationError, "open_dashboard: #{field} is required" if public_send(field).to_s.strip.empty?
        end
        raise ConfigurationError, "open_dashboard: locale must look like it or en-US" unless LOCALE_FORMAT.match?(locale.to_s)
        raise ConfigurationError, "open_dashboard: at most #{MAX_METRICS} metrics" if @metrics.size > MAX_METRICS
      end
    end
  end
end
