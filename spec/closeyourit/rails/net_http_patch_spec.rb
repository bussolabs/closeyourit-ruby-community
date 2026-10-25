# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::NetHTTPPatch do
  # Fake class simulating Net::HTTP: `address` (host) + `request` (round-trip). The patch is prepended
  # → it intercepts `request`, times it, and pushes the call into the current Scope's profile.
  let(:http_class) do
    Class.new do
      def initialize(address) = @address = address
      attr_reader :address
      def request(_req, _body = nil) = :response
      prepend CloseYourIt::Rails::NetHTTPPatch
    end
  end

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.detect_performance_issues = true
      c.capture_external_http = true
      over.each { |k, v| c.public_send("#{k}=", v) }
    end
  end

  before { CloseYourIt::Scope.reset! }
  after { CloseYourIt::Scope.reset! }

  let(:req) { double("request", path: "/v1/charges/ch_12345") }

  it "records the external call in the profile (host + templatized path)" do
    enable!
    http_class.new("api.stripe.com").request(req)
    calls = CloseYourIt::Scope.current.performance_profile.external_calls
    expect(calls.size).to eq(1)
    expect(calls.first[:host]).to eq("api.stripe.com")
    expect(calls.first[:path]).to eq("/v1/charges/ch_<n>")
    expect(calls.first[:duration_ms]).to be >= 0
  end

  it "returns the original response (transparent)" do
    enable!
    expect(http_class.new("api.stripe.com").request(req)).to eq(:response)
  end

  it "excludes calls to the CloseYourIt endpoint (no telemetry loop)" do
    enable!
    http_class.new("closeyour.it").request(req)
    expect(CloseYourIt::Scope.current.performance_profile.external_calls).to be_empty
  end

  it "is a no-op when detect_performance_issues is OFF" do
    enable!(detect_performance_issues: false)
    http_class.new("api.stripe.com").request(req)
    expect(CloseYourIt::Scope.current.performance_profile.external_calls).to be_empty
  end

  describe "W3C trace context propagation (opt-in, limited per destination)" do
    let(:trace_id)    { "4bf92f3577b34da6a3ce929d0e0e4736" }
    let(:traceparent) { "00-#{trace_id}-00f067aa0ba902b7-01" }

    # Fake request with writable headers (Net::HTTPRequest supports `[]=`/`[]`).
    def traced_request
      Class.new do
        attr_reader :headers

        def initialize
          @headers = {}
        end

        def path
          "/v1/charges"
        end

        def []=(name, value)
          @headers[name] = value
        end

        def [](name)
          @headers[name]
        end

        def delete(name)
          @headers.delete(name)
        end
      end.new
    end

    def propagate!(**over)
      enable!(propagate_trace_context: true, trace_propagation_allowlist: [ "api.stripe.com" ], **over)
    end

    def adopt!(state = nil)
      CloseYourIt::Scope.current.trace_context = CloseYourIt::TraceContext.parse(traceparent, state)
    end

    it "injects traceparent toward an allowlisted host" do
      propagate!
      adopt!
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out["traceparent"]).to eq(traceparent)
    end

    it "also injects tracestate when present" do
      propagate!
      adopt!("vendora=ok")
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out["tracestate"]).to eq("vendora=ok")
    end

    it "does NOT inject toward a host outside the allowlist (external hosts get no internal headers)" do
      propagate!
      adopt!("vendora=ok")
      out = traced_request
      http_class.new("evil.example.com").request(out)
      expect(out.headers).to be_empty
    end

    it "never emits the baggage header (no internal context/PII downstream)" do
      propagate!
      adopt!("vendora=ok")
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out.headers.keys).to contain_exactly("traceparent", "tracestate")
    end

    it "does NOT inject toward the CloseYourIt endpoint itself (no self-propagation)" do
      propagate!(trace_propagation_allowlist: [ "closeyour.it" ])
      adopt!
      out = traced_request
      http_class.new("closeyour.it").request(out)
      expect(out.headers).to be_empty
    end

    it "injects nothing when propagation is OFF, even toward an allowlisted host" do
      enable!(trace_propagation_allowlist: [ "api.stripe.com" ])
      adopt!
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out.headers).to be_empty
    end

    it "neither raises nor injects when the scope has no trace context" do
      propagate!
      out = traced_request
      expect { http_class.new("api.stripe.com").request(out) }.not_to raise_error
      expect(out.headers).to be_empty
    end

    it "propagates even with detect_performance_issues OFF (independent opt-in)" do
      propagate!(detect_performance_issues: false)
      adopt!
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out["traceparent"]).to eq(traceparent)
    end

    it "keeps the incoming sampled flag (00 stays 00 downstream)" do
      propagate!
      CloseYourIt::Scope.current.trace_context =
        CloseYourIt::TraceContext.parse("00-#{trace_id}-00f067aa0ba902b7-00")
      out = traced_request
      http_class.new("api.stripe.com").request(out)
      expect(out["traceparent"]).to end_with("-00")
    end

    it "nested requests in the same scope share the trace-id" do
      propagate!
      adopt!
      first = traced_request
      second = traced_request
      http_class.new("api.stripe.com").request(first)
      http_class.new("api.stripe.com").request(second)
      expect(first["traceparent"]).to eq(second["traceparent"])
      expect(first["traceparent"]).to include(trace_id)
    end

    it "cross-host redirect: the target outside the allowlist gets no headers" do
      propagate!
      adopt!
      allowed = traced_request
      redirected = traced_request
      http_class.new("api.stripe.com").request(allowed)      # 1st call: allowlisted host
      http_class.new("cdn.other.com").request(redirected)    # redirect to an unauthorized host
      expect(allowed["traceparent"]).to eq(traceparent)
      expect(redirected.headers).to be_empty
    end

    it "cross-host redirect with a REUSED request: leftover headers are removed (no leak)" do
      propagate!
      adopt!("vendora=ok")
      out = traced_request
      http_class.new("api.stripe.com").request(out)          # allowlisted host: injects
      expect(out["traceparent"]).to eq(traceparent)
      http_class.new("cdn.other.com").request(out)           # same req reused toward an unauthorized host
      expect(out.headers).to be_empty                        # internal headers do not leak downstream
    end

    it "a Regexp in the allowlist authorizes subdomains" do
      propagate!(trace_propagation_allowlist: [ /\Aapi\..+\.internal\z/ ])
      adopt!
      out = traced_request
      http_class.new("api.payments.internal").request(out)
      expect(out["traceparent"]).to eq(traceparent)
    end
  end
end
