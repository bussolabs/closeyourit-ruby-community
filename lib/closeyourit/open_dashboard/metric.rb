# frozen_string_literal: true

module CloseYourIt
  module OpenDashboard
    # Raised at boot when the service declares a metric the standard does not allow.
    class ConfigurationError < StandardError; end

    # One metric of the Open Dashboard standard. Rules are checked when the service boots, so a bad
    # declaration fails the deploy instead of producing an invalid response in production.
    class Metric
      TYPES = %w[count money percent duration].freeze
      INTEGER_TYPES = %w[count money].freeze
      PERIODS = { "1d" => 1, "7d" => 7, "30d" => 30, "90d" => 90, "365d" => 365 }.freeze
      BETTER = %w[up down].freeze
      KEY_FORMAT = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/
      CURRENCY_FORMAT = /\A[A-Z]{3}\z/
      UNAVAILABLE = "unavailable"
      SECONDS_PER_DAY = 86_400

      attr_reader :key

      def initialize(key, label:, group:, type:, currency: nil, period: "30d", better: nil, &block)
        @key = key.to_s
        @label = label.to_s
        @group = group.to_s
        @type = type.to_s
        @currency = currency
        @period = period.to_s
        @better = better&.to_s
        @block = block
        validate!
      end

      # The block gets the start of the comparison period. A failure never breaks the other metrics:
      # it is reported to CloseYourIt and the metric goes out as unavailable.
      def to_h(now)
        since = now - (PERIODS.fetch(@period) * SECONDS_PER_DAY)
        identity.merge(values(@block.call(since)))
      rescue StandardError => e
        CloseYourIt.capture_exception(e, handled: true)
        identity.merge(value: nil, error: UNAVAILABLE)
      end

      private

      def identity
        { key: @key, label: @label, group: @group, type: @type, currency: @currency, better: @better }.compact
      end

      def values(result)
        return { value: number(result) } unless result.is_a?(Hash)

        out = { value: number(result.fetch(:value)) }
        out.merge!(previous: number(result[:previous]), period: @period) unless result[:previous].nil?
        out
      end

      # Returns the value to emit: an Integer for count/money, a Float for percent/duration.
      def number(value)
        reject("value must be numeric") unless value.is_a?(Numeric)
        reject("value must be finite") unless !value.respond_to?(:finite?) || value.finite?

        normalised = INTEGER_TYPES.include?(@type) ? whole(value) : Float(value)
        check_range(normalised)
        normalised
      end

      def whole(value)
        reject("#{@type} must be an integer") unless value == value.to_i

        value.to_i
      end

      def check_range(value)
        reject("count must not be negative") if @type == "count" && value.negative?
        reject("percent must be between 0 and 100") if @type == "percent" && !value.between?(0, 100)
        reject("duration must not be negative") if @type == "duration" && value.negative?
      end

      def reject(message)
        raise TypeError, "open_dashboard metric #{@key}: #{message}"
      end

      def validate!
        fail_with("key must be lowercase and dotted, e.g. users.registered") unless KEY_FORMAT.match?(@key)
        fail_with("label is blank") if @label.strip.empty?
        fail_with("group is blank") if @group.strip.empty?
        fail_with("type must be one of #{TYPES.join(', ')}") unless TYPES.include?(@type)
        validate_currency!
        fail_with("period must be one of #{PERIODS.keys.join(', ')}") unless PERIODS.key?(@period)
        fail_with("better must be up or down") if @better && !BETTER.include?(@better)
        fail_with("a block computing the value is required") unless @block
      end

      def validate_currency!
        if @type == "money"
          fail_with("money needs an ISO 4217 currency, e.g. EUR") unless CURRENCY_FORMAT.match?(@currency.to_s)
        elsif @currency
          fail_with("currency is allowed only on money")
        end
      end

      def fail_with(message)
        raise ConfigurationError, "open_dashboard metric #{@key}: #{message}"
      end
    end
  end
end
