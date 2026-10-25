# frozen_string_literal: true

require_relative "breadcrumb_buffer"
require_relative "performance/request_profile"

module CloseYourIt
  # Per-request (or per-job) context isolated per execution context (Fiber storage):
  # user/tags/extra/contexts/request. Read by ErrorEvent#to_h on the calling thread (synchronous)
  # → the send worker never sees it and the scope does not leak between requests.
  class Scope
    STORAGE_KEY = :__closeyourit_scope

    class << self
      # Scope of the current execution context. Uses `ActiveSupport::IsolatedExecutionState` when
      # present (honors isolation_level: thread on Puma, fiber on Falcon), otherwise
      # `Thread.current` (pure thread-local, NOT inherited by child threads → no bleed).
      def current
        store[STORAGE_KEY] ||= new
      end

      # Reinstalls a previously saved scope. Used by `after_discard` (ActiveJob 7.1+) to get back the
      # scope enriched during `perform` — tags/contexts/breadcrumbs, queries included — after the
      # end-of-`perform` reset detached it from storage (CYRB-19). Symmetric to `reset!`.
      def current=(scope)
        store[STORAGE_KEY] = scope
      end

      # Clears the current scope — called in `ensure` by middleware and jobs (on Puma the
      # thread is reused: without a reset the scope would leak into the next request).
      def reset!
        store[STORAGE_KEY] = nil
      end

      private

      def store
        if defined?(::ActiveSupport::IsolatedExecutionState)
          ::ActiveSupport::IsolatedExecutionState
        else
          ::Thread.current
        end
      end
    end

    attr_accessor :request, :trace_id, :rack_env, :replay_session_id, :trace_context
    attr_reader :user, :tags, :extra, :contexts, :breadcrumbs

    def initialize
      clear
    end

    def set_user(attributes)
      @user.merge!(stringify_keys(attributes))
    end

    def set_tag(key, value)
      @tags[key.to_s] = value
    end

    def set_tags(attributes)
      attributes.each { |key, value| set_tag(key, value) }
    end

    def set_context(key, attributes)
      @contexts[key.to_s] = stringify_keys(attributes)
    end

    def set_extra(key, value)
      @extra[key.to_s] = value
    end

    def add_breadcrumb(breadcrumb)
      @breadcrumbs.add(breadcrumb)
    end

    # Per-request performance profile (queries + external HTTP). Lazy: created on first access,
    # reset by #clear at the end of the request. Subscribers::RequestPerformance computes the verdict.
    def performance_profile
      @performance_profile ||= Performance::RequestProfile.new
    end

    def clear
      @user        = {}
      @tags        = {}
      @extra       = {}
      @contexts    = {}
      @request     = nil
      @rack_env    = nil
      @trace_id    = nil
      @replay_session_id = nil
      # W3C trace context of the request (CloseYourIt::TraceContext): populated only when opt-in
      # propagation is on, consumed by the Net::HTTP patch for outgoing headers.
      @trace_context = nil
      @breadcrumbs = BreadcrumbBuffer.new(CloseYourIt.configuration.max_breadcrumbs)
      @performance_profile = nil
    end

    # Non-empty subset in Sentry event shape (user/tags/extra/contexts/request), merged into the
    # payload by ErrorEvent#to_h. tags/extra/contexts go through the Scrubber (recursive denylist by
    # key): the backend does NOT scrub them again (Errors::Ingest::Normalize keeps them verbatim),
    # so this is the only safety net against sensitive keys there — R2.
    def to_event_hash
      {
        "user"        => serialize_user,
        "tags"        => scrub(presence(@tags)),
        "extra"       => scrub(presence(@extra)),
        "contexts"    => contexts_payload,
        "request"     => request_payload,
        "breadcrumbs" => breadcrumbs_payload
      }.reject { |_key, value| value.nil? }
    end

    private

    # User contexts + `replay.replay_id` (session replay) when present on the scope: the backend
    # reads contexts.replay.replay_id to link the server error to the video (same spot as the JS
    # path). replay/replay_id are not sensitive keys → they survive the Scrubber.
    def contexts_payload
      merged = @contexts.dup
      merged["replay"] = { "replay_id" => @replay_session_id } if @replay_session_id
      scrub(presence(merged))
    end

    # Redacts the values of sensitive keys preserving the structure (e.g. contexts.runtime stays
    # intact, only values under sensitive keys become [FILTERED]). Reuses the configuration's
    # Scrubber, the same path as breadcrumb.data and log attributes.
    def scrub(hash)
      return hash if hash.nil?

      Scrubber.new(CloseYourIt.configuration).filter_params(hash)
    end

    # Request context + body params (`request.data`) extracted LAZILY here — i.e. only when an
    # event is actually built, never on the request's happy path.
    def request_payload
      return nil if @request.nil?

      data = request_body_data
      data ? @request.merge("data" => data) : @request
    end

    # Body params are user input (PII): sent only with send_pii AND capture_request_body (CYRB-28).
    def request_body_data
      config = CloseYourIt.configuration
      return nil unless config.send_pii && config.capture_request_body
      return nil if @rack_env.nil?

      Rails::RequestBody.extract(@rack_env)
    rescue StandardError
      nil
    end

    # `user.id` always; email/ip_address/username only with `send_pii` (the backend strips them
    # anyway — defense in depth).
    def serialize_user
      return nil if @user.empty?
      return @user if CloseYourIt.configuration.send_pii

      presence(@user.slice("id"))
    end

    def breadcrumbs_payload
      return nil if @breadcrumbs.empty?

      { "values" => @breadcrumbs.to_a }
    end

    def presence(hash)
      hash.empty? ? nil : hash
    end

    def stringify_keys(attributes)
      attributes.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
    end
  end
end
