# frozen_string_literal: true

RSpec.describe "CloseYourIt.capture_message" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  it "sends a message event in Sentry format (message.formatted + level)" do
    enable!
    stub = stub_request(:post, url)

    CloseYourIt.capture_message("disk almost full", level: "warning")

    expect(stub).to have_been_requested
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body.dig("message", "formatted") == "disk almost full" &&
        body["level"] == "warning" &&
        body["platform"] == "ruby"
    }
  end

  it "uses level info by default" do
    enable!
    stub_request(:post, url)
    CloseYourIt.capture_message("hello")
    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body)["level"] == "info" }
  end

  it "scrubs message.formatted with scrub_message_patterns (PII parity with exception.message)" do
    enable!(scrub_message_patterns: [ /hunter2/ ])
    stub_request(:post, url)
    CloseYourIt.capture_message("login with hunter2")
    expect(WebMock).to have_requested(:post, url)
      .with { |req| JSON.parse(req.body).dig("message", "formatted") == "login with [FILTERED]" }
  end

  it "merges the scope (tags/user) into the message" do
    enable!
    stub_request(:post, url)
    CloseYourIt.set_tag(:area, "disk")

    CloseYourIt.capture_message("x")

    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).dig("tags", "area") == "disk" }
  ensure
    CloseYourIt.clear_scope
  end

  it "includes the scope trace_id (parity with capture_exception: log↔error correlation)" do
    enable!
    stub_request(:post, url)
    CloseYourIt::Scope.current.trace_id = "abc123trace"

    CloseYourIt.capture_message("x")

    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body)["trace_id"] == "abc123trace" }
  ensure
    CloseYourIt.clear_scope
  end

  it "applies before_send (it can drop the message)" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.before_send = ->(_payload) { nil }
    end
    stub = stub_request(:post, url)

    CloseYourIt.capture_message("dropped")

    expect(stub).not_to have_been_requested
  end

  it "is a no-op when the gem is disabled" do
    stub = stub_request(:post, url)
    CloseYourIt.capture_message("x")
    expect(stub).not_to have_been_requested
  end
end
