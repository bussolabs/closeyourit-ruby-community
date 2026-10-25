# frozen_string_literal: true

RSpec.describe "CloseYourIt.capture_exception" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  # async_threads: 0 → synchronous send, deterministic for WebMock.
  def configure!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |k, v| c.public_send("#{k}=", v) }
    end
  end

  def sample_exception
    raise "boom"
  rescue StandardError => e
    e
  end

  it "sends a Sentry event on the /events path (1 POST)" do
    configure!
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["level"] == "error" && body.dig("exception", "values").is_a?(Array)
    }
  end

  it "deduplicates the same exception (a single send)" do
    configure!
    stub = stub_request(:post, url)
    exception = sample_exception

    CloseYourIt.capture_exception(exception)
    CloseYourIt.capture_exception(exception)

    expect(stub).to have_been_requested.times(1)
  end

  it "does not send exceptions in excluded_exceptions" do
    stub_const("Ignored::Boring", Class.new(StandardError))
    configure!(excluded_exceptions: [ "Ignored::Boring" ])
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(Ignored::Boring.new("nope"))

    expect(stub).not_to have_been_requested
  end

  it "does not send when before_send returns nil" do
    configure!(before_send: ->(_payload) { nil })
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).not_to have_been_requested
  end

  it "is a no-op without project_id" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = nil
      c.async_threads = 0
    end
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).not_to have_been_requested
  end
end
