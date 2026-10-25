# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::RequestContext do
  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  let(:env) do
    {
      "REQUEST_METHOD"     => "GET",
      "rack.url_scheme"    => "https",
      "HTTP_HOST"          => "app.test",
      "PATH_INFO"          => "/orders/42",
      "QUERY_STRING"       => "token=secret&page=2",
      "REMOTE_ADDR"        => "1.2.3.4",
      "HTTP_ACCEPT"        => "text/html",
      "HTTP_USER_AGENT"    => "RSpec",
      "HTTP_AUTHORIZATION" => "Bearer hunter2",
      "HTTP_COOKIE"        => "session=abc"
    }
  end

  def capture_request_via(app_env)
    captured = :unset
    app = lambda do |_e|
      captured = CloseYourIt::Scope.current.request
      [ 200, {}, [] ]
    end
    described_class.new(app).call(app_env)
    captured
  end

  it "populates the scope with method/url/header allowlist during the request" do
    enable!
    request = capture_request_via(env)

    expect(request["method"]).to eq("GET")
    expect(request["url"]).to eq("https://app.test/orders/42")
    expect(request["headers"]).to include("Accept" => "text/html", "User-Agent" => "RSpec")
  end

  it "never includes sensitive headers (Authorization/Cookie)" do
    enable!
    request = capture_request_via(env)
    expect(request["headers"].keys).not_to include("Authorization", "Cookie")
  end

  it "does not include the URL with the query string (potential PII)" do
    enable!
    request = capture_request_via(env)
    expect(request["url"]).not_to include("token=secret")
  end

  it "excludes query_string and IP when send_pii is false" do
    enable!(send_pii: false)
    request = capture_request_via(env)
    expect(request).not_to have_key("query_string")
    expect(request).not_to have_key("env")
  end

  it "includes query_string and IP when send_pii is true" do
    enable!(send_pii: true)
    request = capture_request_via(env)
    expect(request["query_string"]).to eq("token=secret&page=2")
    expect(request["env"]).to eq("REMOTE_ADDR" => "1.2.3.4")
  end

  it "resets the scope at the end of the request (ensure)" do
    enable!
    described_class.new(->(_e) { [ 200, {}, [] ] }).call(env)
    expect(CloseYourIt::Scope.current.to_event_hash).to eq({})
  end

  it "resets the scope even when the app raises" do
    enable!
    app = ->(_e) { raise "boom" }
    expect { described_class.new(app).call(env) }.to raise_error("boom")
    expect(CloseYourIt::Scope.current.to_event_hash).to eq({})
  end

  it "does not populate the request when the gem is disabled" do
    # no enable! → CloseYourIt.enabled? is false
    expect(capture_request_via(env)).to be_nil
  end

  it "does not populate the request when capture_request is false" do
    enable!(capture_request: false)
    expect(capture_request_via(env)).to be_nil
  end

  it "returns the app response unchanged" do
    enable!
    app = ->(_e) { [ 201, { "X" => "1" }, [ "body" ] ] }
    expect(described_class.new(app).call(env)).to eq([ 201, { "X" => "1" }, [ "body" ] ])
  end

  describe "trace_id (log↔error correlation)" do
    def capture_trace_via(app_env)
      captured = :unset
      app = lambda do |_e|
        captured = CloseYourIt::Scope.current.trace_id
        [ 200, {}, [] ]
      end
      described_class.new(app).call(app_env)
      captured
    end

    it "generates a trace_id during the request" do
      enable!
      expect(capture_trace_via(env)).to be_a(String)
    end

    it "reuses action_dispatch.request_id when present" do
      enable!
      expect(capture_trace_via(env.merge("action_dispatch.request_id" => "req-123"))).to eq("req-123")
    end

    it "reuses X-Request-Id (first entry) when present" do
      enable!
      expect(capture_trace_via(env.merge("HTTP_X_REQUEST_ID" => "req-aaa, req-bbb"))).to eq("req-aaa")
    end

    it "does not set trace_id when the gem is disabled" do
      expect(capture_trace_via(env)).to be_nil
    end

    it "sets the trace_id even with capture_request disabled (independent correlation)" do
      enable!(capture_request: false)
      expect(capture_trace_via(env)).to be_a(String)
    end

    it "falls back to SecureRandom when X-Request-Id is whitespace" do
      enable!
      expect(capture_trace_via(env.merge("HTTP_X_REQUEST_ID" => "   "))).to be_a(String)
    end
  end

  describe "W3C trace context propagation (opt-in)" do
    let(:trace_id)     { "4bf92f3577b34da6a3ce929d0e0e4736" }
    let(:traceparent)  { "00-#{trace_id}-00f067aa0ba902b7-01" }

    def capture_context_via(app_env)
      captured = :unset
      app = lambda do |_e|
        captured = CloseYourIt::Scope.current.trace_context
        [ 200, {}, [] ]
      end
      described_class.new(app).call(app_env)
      captured
    end

    it "sets up no trace context when propagation is OFF (default)" do
      enable!
      expect(capture_context_via(env.merge("HTTP_TRACEPARENT" => traceparent))).to be_nil
    end

    it "OFF: the trace_id stays the request_id, not the W3C trace-id" do
      enable!
      trace = nil
      app = lambda do |_e|
        trace = CloseYourIt::Scope.current.trace_id
        [ 200, {}, [] ]
      end
      described_class.new(app).call(env.merge("action_dispatch.request_id" => "req-123",
                                              "HTTP_TRACEPARENT" => traceparent))
      expect(trace).to eq("req-123")
    end

    it "adopts a valid incoming traceparent (trace-id kept)" do
      enable!(propagate_trace_context: true)
      context = capture_context_via(env.merge("HTTP_TRACEPARENT" => traceparent))
      expect(context.trace_id).to eq(trace_id)
    end

    it "correlates events: the trace_id becomes the incoming W3C trace-id" do
      enable!(propagate_trace_context: true)
      trace = nil
      app = lambda do |_e|
        trace = CloseYourIt::Scope.current.trace_id
        [ 200, {}, [] ]
      end
      described_class.new(app).call(env.merge("action_dispatch.request_id" => "req-123",
                                              "HTTP_TRACEPARENT" => traceparent))
      expect(trace).to eq(trace_id)
    end

    it "adopts the incoming tracestate along with the traceparent" do
      enable!(propagate_trace_context: true)
      context = capture_context_via(env.merge("HTTP_TRACEPARENT" => traceparent,
                                              "HTTP_TRACESTATE" => "vendora=ok"))
      expect(context.tracestate).to eq("vendora=ok")
    end

    it "generates a root context when the incoming traceparent is malformed" do
      enable!(propagate_trace_context: true)
      context = capture_context_via(env.merge("HTTP_TRACEPARENT" => "broken"))
      expect(context).to be_a(CloseYourIt::TraceContext)
      expect(context.trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(context.trace_id).not_to eq(trace_id)
    end

    it "generates a root context when no traceparent arrives (originating service)" do
      enable!(propagate_trace_context: true)
      context = capture_context_via(env)
      expect(context).to be_a(CloseYourIt::TraceContext)
      expect(context.trace_id).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  it "the event captured during the request carries the request context" do
    enable!
    url = "https://closeyour.it/api/v1/projects/proj-1/events"
    stub_request(:post, url)
    app = ->(_e) { raise "kaboom" }

    stack = described_class.new(CloseYourIt::Rails::CaptureExceptions.new(app))
    expect { stack.call(env) }.to raise_error(RuntimeError, "kaboom")

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body).dig("request", "method") == "GET"
    }
  end

  describe "request body (request.data, extracted lazily when the error happens)" do
    let(:post_env) do
      body = "name=Anna&password=hunter2"
      env.merge(
        "REQUEST_METHOD" => "POST",
        "CONTENT_TYPE"   => "application/x-www-form-urlencoded",
        "CONTENT_LENGTH" => body.bytesize.to_s,
        "rack.input"     => StringIO.new(body)
      )
    end

    def event_request_data(app_env)
      url = "https://closeyour.it/api/v1/projects/proj-1/events"
      stub_request(:post, url)
      app = ->(_e) { raise "kaboom" }
      stack = described_class.new(CloseYourIt::Rails::CaptureExceptions.new(app))
      expect { stack.call(app_env) }.to raise_error(RuntimeError, "kaboom")

      data = nil
      expect(WebMock).to have_requested(:post, url).with { |req|
        data = JSON.parse(req.body).dig("request", "data")
        true
      }
      data
    end

    it "the event carries the scrubbed body params with send_pii enabled" do
      enable!(send_pii: true)
      expect(event_request_data(post_env)).to eq("name" => "Anna", "password" => "[FILTERED]")
    end

    # CYRB-28 — form content is user input: without send_pii nothing of the body leaves the app,
    # whatever capture_request_body says.
    it "has no request.data when send_pii is false (default)" do
      enable!
      expect(event_request_data(post_env)).to be_nil
    end

    it "has no request.data with capture_request_body disabled" do
      enable!(send_pii: true, capture_request_body: false)
      expect(event_request_data(post_env)).to be_nil
    end

    it "has no request.data on requests without a body" do
      enable!
      expect(event_request_data(env)).to be_nil
    end
  end
end
