# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::CaptureExceptions do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  def enable!
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
    end
  end

  it "re-raises the exception and captures it as a Sentry event (level=error)" do
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { raise "kaboom" }

    expect { described_class.new(app).call({}) }.to raise_error(RuntimeError, "kaboom")

    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body)["level"] == "error" }
  end

  # CYRB-35: a frozen exception used to come back as the gem's FrozenError instead of the app's own.
  it "re-raises the very same frozen exception and captures it once" do
    enable!
    stub = stub_request(:post, url)
    frozen = RuntimeError.new("frozen kaboom").freeze
    app = ->(_env) { raise frozen }

    expect { described_class.new(app).call({}) }.to raise_error { |error| expect(error).to equal(frozen) }

    expect(stub).to have_been_requested.times(1)
  end

  # Backtrace set BEFORE freezing, frozen while propagating: the middleware receives this very
  # instance. A rescue + re-raise would make Ruby raise an unfrozen copy of it; the original must
  # come out instead, unchanged.
  it "lets the very same frozen exception with a backtrace through, message and backtrace intact" do
    enable!
    stub = stub_request(:post, url)
    original = RuntimeError.new("frozen with backtrace")
    original.set_backtrace(caller_locations)
    backtrace = original.backtrace.dup
    app = lambda do |_env|
      raise original
    ensure
      original.freeze
    end

    expect { described_class.new(app).call({}) }.to raise_error { |error|
      expect(error).to equal(original)
      expect(error).to be_frozen
      expect(error.message).to eq("frozen with backtrace")
      expect(error.backtrace).to eq(backtrace)
    }
    expect(backtrace).not_to be_empty
    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req|
      value = JSON.parse(req.body).dig("exception", "values").last
      value["value"] == "frozen with backtrace" && value.dig("stacktrace", "frames").size == backtrace.size
    }
  end

  it "does not capture the exception its caller is handling when the request ends normally" do
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }

    response = begin
      raise "outer, already handled by the caller"
    rescue StandardError
      described_class.new(app).call({})
    end

    expect(response).to eq([ 200, {}, [ "ok" ] ])
    expect(stub).not_to have_been_requested
  end

  it "does not capture a throw that unwinds through it" do
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { throw :halt, [ 302, {}, [] ] }

    expect(catch(:halt) { described_class.new(app).call({}) }).to eq([ 302, {}, [] ])
    expect(stub).not_to have_been_requested
  end

  it "re-raises the app's exception even when the gem fails while capturing it" do
    enable!
    CloseYourIt.internal_logger = instance_double(Logger, error: nil)
    allow(CloseYourIt::ErrorEvent).to receive(:from_exception).and_raise(NoMethodError, "gem bug")
    app = ->(_env) { raise "kaboom" }

    expect { described_class.new(app).call({}) }.to raise_error(RuntimeError, "kaboom")
  ensure
    CloseYourIt.internal_logger = nil
  end

  it "lets normal responses through without capturing" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }

    expect(CloseYourIt).not_to receive(:capture_exception)
    expect(described_class.new(app).call({})).to eq([ 200, {}, [ "ok" ] ])
  end

  it "does not send excluded exceptions (e.g. RecordNotFound) but re-raises them" do
    stub_const("ActiveRecord::RecordNotFound", Class.new(StandardError))
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { raise ActiveRecord::RecordNotFound, "missing" }

    expect { described_class.new(app).call({}) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(stub).not_to have_been_requested
  end

  # CYRB-46: a bot sends a malformed or forged request, the app rejects it with a 4xx, and the
  # rejection must not reach the error channel. One case per exclusion added by the ticket, because
  # each is raised by a different layer (middleware, CSRF check, format negotiation, params parser).
  [
    "ActionDispatch::RemoteIp::IpSpoofAttackError",
    "ActionController::InvalidAuthenticityToken",
    "ActionController::UnknownFormat",
    "ActionController::BadRequest",
    "ActionDispatch::Http::MimeNegotiation::InvalidType"
  ].each do |class_name|
    it "does not send #{class_name} raised by a malformed request" do
      stub_const(class_name, Class.new(StandardError))
      rejection = Object.const_get(class_name)
      enable!
      stub = stub_request(:post, url)
      app = ->(_env) { raise rejection, "bot" }

      expect { described_class.new(app).call({}) }.to raise_error(rejection)
      expect(stub).not_to have_been_requested
    end
  end

  # CYRB-46: the exclusion is a DEFAULT, not a verdict — whoever suspects a real frontend bug behind
  # one of these rejections takes it off the list and gets the errors back.
  it "sends a default-excluded rejection again when the app takes it off the list" do
    stub_const("ActionController::UnknownFormat", Class.new(StandardError))
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.excluded_exceptions -= [ "ActionController::UnknownFormat" ]
    end
    stub = stub_request(:post, url)
    app = ->(_env) { raise ActionController::UnknownFormat, "no template" }

    expect { described_class.new(app).call({}) }.to raise_error(ActionController::UnknownFormat)
    expect(stub).to have_been_requested.times(1)
  end
end
