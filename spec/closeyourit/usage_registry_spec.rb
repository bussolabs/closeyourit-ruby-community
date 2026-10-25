# frozen_string_literal: true

# CYSK-29 — usage telemetry: counts are indicative, only last_seen_at is load-bearing; the registry
# is emptied on every flush; truncation is declared (and disqualifies the kind on the scanner side).
RSpec.describe CloseYourIt::UsageRegistry do
  let(:client) { instance_double(CloseYourIt::Client, flush_usage: nil) }
  let(:configuration) do
    instance_double(CloseYourIt::Configuration,
                    usage_enabled: true, usage_flush_interval: 300, usage_max_symbols: 3)
  end

  subject(:registry) { described_class.new(client: client, configuration: configuration) }

  it "records and flushes the symbols seen, then the registry starts empty again" do
    registry.record("route", "Users#index")
    registry.record("route", "Users#index")
    registry.record("job", "MailJob")

    registry.flush

    expect(client).to have_received(:flush_usage) do |symbols:, truncated:, **|
      expect(truncated).to be(false)
      expect(symbols).to contain_exactly(
        hash_including(kind: "route", symbol: "Users#index", count: 2),
        hash_including(kind: "job", symbol: "MailJob", count: 1)
      )
    end

    registry.flush # empty → no second POST
    expect(client).to have_received(:flush_usage).once
  end

  it "declares truncated beyond the distinct symbol cap: the flag that disqualifies the kind" do
    registry.record("route", "A#a")
    registry.record("route", "B#b")
    registry.record("custom", "checkout.legacy")
    registry.record("route", "C#c") # fourth distinct symbol: beyond usage_max_symbols=3

    registry.flush

    expect(client).to have_received(:flush_usage) do |symbols:, truncated:, **|
      expect(truncated).to be(true)
      expect(symbols.size).to eq(3)
    end
  end

  it "rejects an off-contract symbol: an interpolated URL never enters the symbol table" do
    registry.record("route", "/users/42?token=abc")
    registry.record("made_up", "X")
    registry.record("custom", "a" * 201)

    registry.flush

    expect(client).not_to have_received(:flush_usage)
  end

  it "records nothing with usage_enabled OFF" do
    allow(configuration).to receive(:usage_enabled).and_return(false)

    registry.record("route", "Users#index")
    registry.flush

    expect(client).not_to have_received(:flush_usage)
  end

  it "a raising flush does not propagate into the app: a lost window falsifies nothing" do
    allow(client).to receive(:flush_usage).and_raise(StandardError, "network down")
    registry.record("route", "Users#index")

    expect { registry.flush }.not_to raise_error
  end

  it "shutdown flushes what is left" do
    registry.record("route", "Users#index")

    registry.shutdown

    expect(client).to have_received(:flush_usage).once
  end
end

# Side branches the coverage gate requires to be covered as much as the happy path.
RSpec.describe CloseYourIt::UsageRegistry, "timer and interval" do
  let(:client) { instance_double(CloseYourIt::Client, flush_usage: nil) }

  it "creates the timer ONCE, with the configured interval" do
    configuration = instance_double(CloseYourIt::Configuration,
                                    usage_enabled: true, usage_flush_interval: 120, usage_max_symbols: 10)
    registry = described_class.new(client: client, configuration: configuration)

    registry.record("route", "A#a")
    registry.record("route", "B#b")

    expect(registry.timer.execution_interval).to eq(120)
    registry.shutdown
  end

  it "falls back to 300 seconds for an invalid interval" do
    configuration = instance_double(CloseYourIt::Configuration,
                                    usage_enabled: true, usage_flush_interval: 0, usage_max_symbols: 10)
    registry = described_class.new(client: client, configuration: configuration)

    registry.record("route", "A#a")

    expect(registry.timer.execution_interval).to eq(300)
    registry.shutdown
  end
end

RSpec.describe "CloseYourIt.used" do
  it "is a no-op without init: no registry created" do
    CloseYourIt.instance_variable_set(:@configuration, nil)
    expect(CloseYourIt.used("checkout.legacy")).to be_nil
  end

  it "records a custom key when the gem is configured and enabled" do
    CloseYourIt.init do |config|
      config.endpoint_url = "https://example.test"
      config.token = "cyi_x"
      config.project_id = "p1"
    end
    allow(CloseYourIt.usage_registry).to receive(:record)

    CloseYourIt.used("checkout.legacy")

    expect(CloseYourIt.usage_registry).to have_received(:record).with("custom", "checkout.legacy")
  ensure
    CloseYourIt.instance_variable_set(:@configuration, nil)
  end
end
