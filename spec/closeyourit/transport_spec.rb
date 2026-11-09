# frozen_string_literal: true

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
end
