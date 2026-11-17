# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::ErrorSubscriber do
  subject(:subscriber) { described_class.new }

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

  def error
    raise "handled boom"
  rescue RuntimeError => e
    e
  end

  it "captures a handled error mapping severity→level and mechanism.handled=true" do
    enable!
    stub_request(:post, url)

    subscriber.report(error, handled: true, severity: :warning, context: { "controller" => "Orders" })

    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["level"] == "warning" &&
        body.dig("exception", "values").last.dig("mechanism", "handled") == true &&
        body.dig("contexts", "rails_error", "controller") == "Orders"
    }
  end

  it "maps an unknown severity to level error" do
    enable!
    stub_request(:post, url)
    subscriber.report(error, handled: true, severity: :bogus, context: {})
    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body)["level"] == "error" }
  end

  it "does not capture when capture_handled_errors is false" do
    enable!(capture_handled_errors: false)
    stub = stub_request(:post, url)
    subscriber.report(error, handled: true, severity: :error, context: {})
    expect(stub).not_to have_been_requested
  end

  it "ignores the sources in the denylist" do
    enable!
    stub = stub_request(:post, url)
    subscriber.report(error, handled: true, severity: :error, context: {}, source: "closeyourit")
    expect(stub).not_to have_been_requested
  end

  # CYRB-35: a frozen error the Rack middleware already reported, then reported again through
  # Rails.error, is neither sent twice nor turned into the gem's FrozenError.
  it "dedups a frozen error already captured by the middleware (a single send, no raise)" do
    enable!
    stub = stub_request(:post, url)
    frozen = RuntimeError.new("frozen handled boom").freeze
    app = ->(_env) { raise frozen }

    expect { CloseYourIt::Rails::CaptureExceptions.new(app).call({}) }
      .to raise_error { |raised| expect(raised).to equal(frozen) }
    expect { subscriber.report(frozen, handled: true, severity: :error, context: {}) }.not_to raise_error

    expect(stub).to have_been_requested.once
    expect(frozen).to be_frozen
  end
end
