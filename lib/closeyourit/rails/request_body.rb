# frozen_string_literal: true

require "json"
require "uri"
require_relative "../scrubber"

module CloseYourIt
  module Rails
    # Extracts the request body params (`request.data`) at EVENT time — never eagerly on every
    # request (zero overhead on the happy path). Prefers the params already parsed by Rails/Rack in
    # env; falls back to re-reading rack.input (with rewind) only for JSON/form ≤ MAX_BODY_BYTES.
    # Sanitized output (uploads → "[FILE: …]", objects → "[OBJECT: …]", truncated strings) and
    # scrubbed with the same denylist as the rest of the client.
    module RequestBody
      MAX_BODY_BYTES = 65_536
      MAX_DEPTH = 8
      MAX_STRING = 1024

      FORM_TYPE = "application/x-www-form-urlencoded"
      JSON_TYPE = "application/json"

      class << self
        def extract(env)
          params = parsed_params(env) || raw_params(env)
          return nil if params.nil? || params.empty?

          Scrubber.new(CloseYourIt.configuration).filter_params(sanitize(params, 0))
        rescue StandardError
          nil
        end

        private

        # Params already parsed upstream (ActionDispatch or Rack): no body re-read.
        def parsed_params(env)
          env["action_dispatch.request.request_parameters"] || env["rack.request.form_hash"]
        end

        def raw_params(env)
          raw = read_body(env)
          return nil if raw.nil? || raw.empty?

          case env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
          when JSON_TYPE
            value = JSON.parse(raw)
            value.is_a?(Hash) ? value : { "_json" => value }
          when FORM_TYPE
            # Flat fallback (stdlib): the real path with nesting goes through the already parsed params.
            URI.decode_www_form(raw).to_h
          end
        rescue JSON::ParserError, ArgumentError
          nil
        end

        def read_body(env)
          input = env["rack.input"]
          return nil if input.nil?

          length = env["CONTENT_LENGTH"].to_i
          return nil if length <= 0 || length > MAX_BODY_BYTES

          input.rewind if input.respond_to?(:rewind)
          raw = input.read(MAX_BODY_BYTES)
          input.rewind if input.respond_to?(:rewind)
          raw
        end

        def sanitize(value, depth)
          return "[TRUNCATED]" if depth > MAX_DEPTH

          case value
          when Hash    then value.each_with_object({}) { |(key, val), acc| acc[key.to_s] = sanitize(val, depth + 1) }
          when Array   then value.map { |item| sanitize(item, depth + 1) }
          when String  then value.size > MAX_STRING ? "#{value[0, MAX_STRING]}…" : value
          when Numeric, true, false, nil then value
          else
            if value.respond_to?(:original_filename)
              "[FILE: #{value.original_filename}]"
            else
              "[OBJECT: #{value.class.name}]"
            end
          end
        end
      end
    end
  end
end
