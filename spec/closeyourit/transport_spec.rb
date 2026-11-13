# frozen_string_literal: true

RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe CloseYourIt::Transport do
  subject(:transport) { described_class.new(config) }

  let(:config) do
    CloseYourIt::Configuration.new.tap do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
    end
  end

  let(:path) { "/api/v1/projects/proj-1/events" }
  let(:url) { "https://closeyour.it#{path}" }

  it "POSTs to the given path with Bearer token and JSON body" do
    stub = stub_request(:post, url)

    transport.send_event({ "level" => "error" }, path: path)

    expect(stub).to have_been_requested
    expect(WebMock).to have_requested(:post, url).with(
      headers: { "Authorization" => "Bearer tok", "Content-Type" => "application/json" },
      body: { "level" => "error" }.to_json
    )
  end

  it "routes different paths (errors vs metrics)" do
    metrics = "https://closeyour.it/api/v1/projects/proj-1/metrics"
    stub = stub_request(:post, metrics)

    transport.send_event({ "kind" => "slow_query" }, path: "/api/v1/projects/proj-1/metrics")

    expect(stub).to have_been_requested
  end

  it "does not raise on a network error and returns nil" do
    stub_request(:post, url).to_timeout
    allow(CloseYourIt.internal_logger).to receive(:error)

    result = nil
    expect { result = transport.send_event({ "level" => "error" }, path: path) }.not_to raise_error
    expect(result).to be_nil
  end

  it "increments stats.failed and logs on a network error" do
    stub_request(:post, url).to_timeout
    allow(CloseYourIt.internal_logger).to receive(:error)

    expect { transport.send_event({ "level" => "error" }, path: path) }
      .to change { CloseYourIt.stats[:failed] }.by(1)
    expect(CloseYourIt.internal_logger).to have_received(:error)
  end

  it "increments stats.sent on a 2xx response" do
    stub_request(:post, url).to_return(status: 202)

    expect { transport.send_event({ "level" => "error" }, path: path) }
      .to change { CloseYourIt.stats[:sent] }.by(1)
  end

  it "logs at warn and increments stats.failed on a non-2xx status" do
    stub_request(:post, url).to_return(status: 401)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    expect { transport.send_event({ "level" => "error" }, path: path) }
      .to change { CloseYourIt.stats[:failed] }.by(1)
    expect(CloseYourIt.internal_logger).to have_received(:warn).with(/HTTP 401/)
  end

  it "follows the apex → www redirect keeping POST, body and Bearer" do
    www = "https://www.closeyour.it#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => www })
    final = stub_request(:post, www).to_return(status: 202, body: '{"id":"e1"}')

    transport.send_event({ "level" => "error" }, path: path)

    expect(final).to have_been_requested
    expect(WebMock).to have_requested(:post, www).with(
      headers: { "Authorization" => "Bearer tok", "Content-Type" => "application/json" },
      body: { "level" => "error" }.to_json
    )
  end

  it "stops after MAX_REDIRECTS — no infinite loop on a cyclic redirect" do
    www = "https://www.closeyour.it#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => www })
    stub_request(:post, www).to_return(status: 301, headers: { "Location" => url })
    allow(CloseYourIt.internal_logger).to receive(:warn)

    result = nil
    expect { result = transport.send_event({ "level" => "error" }, path: path) }.not_to raise_error
    expect(result).to be_a(Net::HTTPRedirection)
    expect(a_request(:post, www)).to have_been_made
  end

  it "does NOT follow a redirect to a different host: nothing reaches it, the send fails (CYRB-31)" do
    evil = "https://evil.example#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => evil })
    stub_request(:post, evil).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    sent_before = CloseYourIt.stats[:sent]
    result = nil
    expect { result = transport.send_event({ "level" => "error" }, path: path) }
      .to change { CloseYourIt.stats[:failed] }.by(1)
    expect(CloseYourIt.stats[:sent]).to eq(sent_before)
    expect(result).to be_a(Net::HTTPRedirection)
    expect(a_request(:post, evil)).not_to have_been_made
  end

  it "does NOT follow an https→http downgrade (same host): nothing travels in clear (CYRB-31)" do
    insecure = "http://closeyour.it#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => insecure })
    stub_request(:post, insecure).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(a_request(:post, insecure)).not_to have_been_made
  end

  it "does NOT follow a redirect that changes port on the same host (CYRB-22, CYRB-31)" do
    other_port = "https://closeyour.it:8443#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => other_port })
    stub_request(:post, other_port).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(a_request(:post, other_port)).not_to have_been_made
  end

  it "logs a warning naming the refused redirect target and why (CYRB-31)" do
    evil = "https://evil.example#{path}"
    stub_request(:post, url).to_return(status: 302, headers: { "Location" => evil })
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(CloseYourIt.internal_logger).to have_received(:warn)
      .with(%r{redirect to https://evil\.example:443 on #{Regexp.escape(path)} refused: it leaves the configured endpoint})
  end

  it "resends the Bearer when the redirect states the default port explicitly (443 == implicit)" do
    explicit_port = "https://www.closeyour.it:443#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => explicit_port })
    stub_request(:post, explicit_port).to_return(status: 202)

    transport.send_event({ "level" => "error" }, path: path)

    expect(WebMock).to have_requested(:post, explicit_port)
      .with(headers: { "Authorization" => "Bearer tok" })
  end

  it "resends the Bearer on the canonical http→https upgrade (endpoint configured in clear)" do
    config.endpoint_url = "http://closeyour.it"
    secure = "https://closeyour.it#{path}"
    stub_request(:post, "http://closeyour.it#{path}").to_return(status: 301, headers: { "Location" => secure })
    stub_request(:post, secure).to_return(status: 202)

    transport.send_event({ "level" => "error" }, path: path)

    expect(WebMock).to have_requested(:post, secure).with(headers: { "Authorization" => "Bearer tok" })
  end

  it "does NOT follow an http→https upgrade to a non-standard port (CYRB-31)" do
    config.endpoint_url = "http://closeyour.it"
    secure = "https://closeyour.it:8443#{path}"
    stub_request(:post, "http://closeyour.it#{path}").to_return(status: 301, headers: { "Location" => secure })
    stub_request(:post, secure).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(a_request(:post, secure)).not_to have_been_made
  end

  it "in an apex → www → other port chain the send stops at the port change (CYRB-31)" do
    www = "https://www.closeyour.it#{path}"
    other_port = "https://www.closeyour.it:8443#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => www })
    stub_request(:post, www).to_return(status: 301, headers: { "Location" => other_port })
    stub_request(:post, other_port).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    result = transport.send_event({ "level" => "error" }, path: path)

    expect(WebMock).to have_requested(:post, www).with(headers: { "Authorization" => "Bearer tok" })
    expect(a_request(:post, other_port)).not_to have_been_made
    expect(result).to be_a(Net::HTTPRedirection)
  end

  it "a chain that would come back to the origin stops at its first foreign hop (CYRB-31)" do
    other_port = "https://closeyour.it:8443#{path}"
    www = "https://www.closeyour.it#{path}"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => other_port })
    stub_request(:post, other_port).to_return(status: 301, headers: { "Location" => www })
    stub_request(:post, www).to_return(status: 202)
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(a_request(:post, other_port)).not_to have_been_made
    expect(a_request(:post, www)).not_to have_been_made
  end

  it "a relative Location stays authorized: host and port do not change" do
    moved = "https://closeyour.it/api/v2/projects/proj-1/events"
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => "/api/v2/projects/proj-1/events" })
    stub_request(:post, moved).to_return(status: 202)

    transport.send_event({ "level" => "error" }, path: path)

    expect(WebMock).to have_requested(:post, moved).with(headers: { "Authorization" => "Bearer tok" })
  end

  it "logs the R- code from the error body on non-2xx (diagnostic DX)" do
    stub_request(:post, url).to_return(
      status: 422, body: '{"error":{"code":"R422-INGEST-001","message":"Malformed event"}}'
    )
    allow(CloseYourIt.internal_logger).to receive(:warn)

    transport.send_event({ "level" => "error" }, path: path)

    expect(CloseYourIt.internal_logger).to have_received(:warn).with(/R422-INGEST-001: Malformed event/)
  end

  # CYRB-44 — a busy server or a passing failure is retried (at most MAX_RETRIES more attempts), a
  # final refusal never is. Waits are not real: #pause is stubbed and records the requested delays.
  describe "retries on transient failures (CYRB-44)" do
    subject(:transport) do
      described_class.new(config, retries: described_class::MAX_RETRIES, random: random).tap do |t|
        allow(t).to receive(:pause) { |seconds| waits << seconds && false }
      end
    end

    let(:random) { instance_double(Random, rand: 0.5) }
    let(:waits) { [] }
    let(:seen) { [] }

    before do
      allow(CloseYourIt.internal_logger).to receive(:warn)
      allow(CloseYourIt.internal_logger).to receive(:error)
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.on_diagnostic = ->(event, details) { seen << [ event, details ] }
      end
    end

    it "delivers on the next attempt when the server was busy" do
      stub_request(:post, url).to_return({ status: 503 }, { status: 202 })

      expect { transport.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:sent] }.by(1)
        .and change { CloseYourIt.stats[:retried] }.by(1)
        .and(not_change { CloseYourIt.stats[:failed] })
      expect(a_request(:post, url)).to have_been_made.twice
    end

    it "makes 3 attempts in all against a server that stays in error, then counts ONE failure" do
      stub_request(:post, url).to_return(status: 500)

      expect { transport.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:failed] }.by(1)
        .and change { CloseYourIt.stats[:retried] }.by(2)
      expect(a_request(:post, url)).to have_been_made.times(3)
      expect(seen.count { |event, _| event == :drop }).to eq(1)
    end

    it "waits a short doubling delay with jitter between attempts" do
      stub_request(:post, url).to_return(status: 502)

      transport.send_event({ "level" => "error" }, path: path)

      # base 1s then 2s, plus rand (0.5) × base.
      expect(waits).to eq([ 1.5, 3.0 ])
    end

    it "never waits more than MAX_RETRY_DELAY, jitter included" do
      allow(random).to receive(:rand).and_return(0.99)
      stub_request(:post, url).to_return(status: 503)
      transport.send_event({ "level" => "error" }, path: path)

      expect(waits).to eq([ 1.99, 3.98 ])
      expect(waits.max).to be <= described_class::MAX_RETRY_DELAY
      expect(described_class::MAX_RETRY_DELAY).to eq(5.0)
    end

    it "honors the server's Retry-After in seconds" do
      stub_request(:post, url).to_return({ status: 429, headers: { "Retry-After" => "1" } }, { status: 202 })

      transport.send_event({ "level" => "error" }, path: path)

      expect(waits).to eq([ 1.0 ])
    end

    it "caps a Retry-After longer than 5 seconds at 5" do
      stub_request(:post, url).to_return({ status: 503, headers: { "Retry-After" => "120" } }, { status: 202 })

      transport.send_event({ "level" => "error" }, path: path)

      expect(waits).to eq([ 5.0 ])
    end

    it "honors a Retry-After given as an HTTP date" do
      stub_request(:post, url).to_return(
        { status: 503, headers: { "Retry-After" => (Time.now + 3).httpdate } }, { status: 202 }
      )

      transport.send_event({ "level" => "error" }, path: path)

      expect(waits.first).to be_between(1.0, 3.0)
    end

    it "falls back to its own delay when Retry-After is unreadable" do
      stub_request(:post, url).to_return({ status: 503, headers: { "Retry-After" => "soon" } }, { status: 202 })

      transport.send_event({ "level" => "error" }, path: path)

      expect(waits).to eq([ 1.5 ])
    end

    it "retries 408, 425 and 429 as \"not now\" statuses" do
      [ 408, 425, 429 ].each do |status|
        stub_request(:post, url).to_return({ status: status }, { status: 202 })

        expect { transport.send_event({ "level" => "error" }, path: path) }
          .to change { CloseYourIt.stats[:sent] }.by(1)
      end
    end

    it "never retries a final refusal: bad data, bad token, unknown project" do
      [ 400, 401, 404, 422 ].each do |status|
        stub_request(:post, url).to_return(status: status)

        expect { transport.send_event({ "level" => "error" }, path: path) }
          .to change { CloseYourIt.stats[:failed] }.by(1)
          .and(not_change { CloseYourIt.stats[:retried] })
      end
      expect(a_request(:post, url)).to have_been_made.times(4)
      expect(waits).to be_empty
    end

    it "does not retry a refused redirect" do
      stub_request(:post, url).to_return(status: 301, headers: { "Location" => "https://evil.example#{path}" })

      transport.send_event({ "level" => "error" }, path: path)

      expect(a_request(:post, url)).to have_been_made.once
    end

    it "retries a network error and a timeout" do
      stub_request(:post, url).to_raise(Errno::ECONNREFUSED).then.to_timeout.then.to_return(status: 202)

      expect { transport.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:sent] }.by(1)
        .and change { CloseYourIt.stats[:retried] }.by(2)
      expect(seen.select { |event, _| event == :retry }.map { |_, details| details[:reason] })
        .to eq(%i[network timeout])
    end

    it "counts a send lost to timeouts as ONE failure and ONE timeout" do
      stub_request(:post, url).to_timeout

      expect { transport.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:failed] }.by(1)
        .and change { CloseYourIt.stats[:timeout] }.by(1)
        .and change { CloseYourIt.stats[:retried] }.by(2)
    end

    it "notifies every retry with its reason, free of the payload" do
      stub_request(:post, url).to_return({ status: 503 }, { status: 202 })

      transport.send_event({ "level" => "error" }, path: path)

      expect(seen).to include([ :retry, { attempt: 1, delay: 1.5, reason: :response, status: 503 } ])
    end

    it "does not retry at all with retries: 0 (synchronous worker)" do
      sync = described_class.new(config)
      allow(sync).to receive(:pause)
      stub_request(:post, url).to_return(status: 503)

      expect { sync.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:failed] }.by(1)
        .and(not_change { CloseYourIt.stats[:retried] })
      expect(sync).not_to have_received(:pause)
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "stops at once when the process exits during the wait: no new attempt" do
      allow(transport).to receive(:pause).and_return(true) # the wait was interrupted
      stub_request(:post, url).to_return(status: 503)

      expect { transport.send_event({ "level" => "error" }, path: path) }
        .to change { CloseYourIt.stats[:failed] }.by(1)
        .and(not_change { CloseYourIt.stats[:retried] }) # the cancelled attempt is not counted
      expect(a_request(:post, url)).to have_been_made.once
    end

    it "starts no retry once stop_retries! was called" do
      transport.stop_retries!
      stub_request(:post, url).to_return(status: 503)

      transport.send_event({ "level" => "error" }, path: path)

      expect(a_request(:post, url)).to have_been_made.once
      expect(waits).to be_empty
    end

    it "reports a wait as interrupted once stop_retries! was called" do
      real = described_class.new(config, retries: 1)
      real.stop_retries!

      # No clock involved: a wait that ran to its end would return false.
      expect(real.send(:pause, 5)).to be(true)
    end

    it "does not retry a payload that cannot be encoded" do
      transport.send_event({ "bad" => Float::NAN }, path: path)

      expect(a_request(:post, url)).not_to have_been_made
      expect(waits).to be_empty
    end
  end
end
