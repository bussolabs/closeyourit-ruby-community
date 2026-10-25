# frozen_string_literal: true

require "time"

module CloseYourIt
  # A single context breadcrumb (query, navigation, custom event) preceding an error.
  # Sentry event shape (`breadcrumbs.values[]`). `data` is already scrubbed upstream (module API).
  class Breadcrumb
    def initialize(message: nil, category: nil, type: "default", level: "info", data: {}, timestamp: nil)
      @timestamp = timestamp || Time.now.utc.iso8601
      @type      = type
      @category  = category
      @level     = level
      @message   = message
      @data      = data
    end

    def to_h
      {
        "timestamp" => @timestamp,
        "type"      => @type,
        "category"  => @category,
        "level"     => @level,
        "message"   => @message,
        "data"      => presence(@data)
      }.reject { |_key, value| value.nil? }
    end

    private

    def presence(value)
      value.nil? || value.empty? ? nil : value
    end
  end
end
