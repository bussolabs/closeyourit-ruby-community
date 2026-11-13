# frozen_string_literal: true

RSpec.describe "ErrorEvent — message scrubbing" do
  it "redacts the value (in exception.values) according to scrub_message_patterns" do
    config = CloseYourIt::Configuration.new
    config.scrub_message_patterns = [ /token=\w+/ ]

    exception =
      begin
        raise "auth failed token=abc123"
      rescue StandardError => e
        e
      end

    payload = CloseYourIt::ErrorEvent.from_exception(exception, configuration: config).to_h
    expect(payload["exception"]["values"].last["value"]).to eq("auth failed [FILTERED]")
  end

  # CYRB-23 — Scenario 1: no configuration, the outgoing payload does not contain the credential.
  # Placeholder token: no real credentials in tests.
  it "redacts the Bearer credential in the value WITHOUT any configuration" do
    exception =
      begin
        raise "401 from the provider (Authorization: Bearer cyi_placeholder_0123456789)"
      rescue StandardError => e
        e
      end

    payload = CloseYourIt::ErrorEvent.from_exception(
      exception, configuration: CloseYourIt::Configuration.new
    ).to_h
    value = payload["exception"]["values"].last["value"]

    expect(value).to eq("401 from the provider (Authorization: Bearer [FILTERED])")
    expect(value).not_to include("cyi_placeholder_0123456789")
  end

  # CYRB-32 — corrupted characters in tags, extra or the exception message must not block the send:
  # they reach the payload repaired (U+FFFD in place of the invalid bytes) and it encodes as JSON.
  describe "invalid UTF-8 (CYRB-32)" do
    after { CloseYourIt.clear_scope }

    let(:exception) do
      raise "decode failed on \xFF\xFE".b
    rescue StandardError => e
      e
    end

    # async_threads: 0 → synchronous send, deterministic for WebMock.
    before do
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.async_threads = 0
      end
    end

    it "repairs an exception message with invalid bytes" do
      payload = CloseYourIt::ErrorEvent.from_exception(exception, configuration: CloseYourIt.configuration).to_h

      expect(payload["exception"]["values"].last["value"]).to eq("decode failed on \uFFFD\uFFFD")
      expect { JSON.generate(payload) }.not_to raise_error
    end

    it "sends the error with its corrupted tag and extra repaired" do
      CloseYourIt.set_tags(origin: "imp\xC3\x28rt".b)
      CloseYourIt.set_extra(:raw_line, "\xFFrow 12".b)
      stub = stub_request(:post, "https://closeyour.it/api/v1/projects/proj-1/events")

      CloseYourIt.capture_exception(exception)

      expect(stub).to have_been_requested
      expect(WebMock).to(have_requested(:post, "https://closeyour.it/api/v1/projects/proj-1/events").with do |req|
        body = JSON.parse(req.body)
        body["tags"] == { "origin" => "imp\uFFFD(rt" } && body["extra"] == { "raw_line" => "\uFFFDrow 12" }
      end)
    end
  end

  # CYRB-43 — a context or extra holding itself used to raise SystemStackError out of
  # capture_exception (no StandardError net catches it): the host app got that instead of its error.
  describe "self-referencing context (CYRB-43)" do
    after { CloseYourIt.clear_scope }

    before do
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.async_threads = 0
      end
    end

    it "sends the error with [Circular] in place of the self-reference" do
      cart = { "items" => 2, "token" => "secret-value" }
      cart["cart"] = cart
      CloseYourIt.set_context(:checkout, cart)
      CloseYourIt.set_extra(:cart, cart)
      url = "https://closeyour.it/api/v1/projects/proj-1/events"
      stub_request(:post, url)

      expect { CloseYourIt.capture_exception(RuntimeError.new("payment failed")) }.not_to raise_error

      expected = { "items" => 2, "token" => "[FILTERED]", "cart" => "[Circular]" }
      expect(WebMock).to(have_requested(:post, url).with do |req|
        body = JSON.parse(req.body)
        # set_context copies the top level (stringified keys): the copy holds the original once.
        body["contexts"]["checkout"] == expected.merge("cart" => expected) && body["extra"]["cart"] == expected
      end)
    end
  end
end
