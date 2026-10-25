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
end
