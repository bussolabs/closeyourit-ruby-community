# frozen_string_literal: true

RSpec.describe CloseYourIt::OpenDashboard do
  def configure(token: "od_live_example", **overrides)
    described_class.configure do |od|
      od.token = token
      od.name = overrides.fetch(:name, "scontino")
      od.app = overrides.fetch(:app, "scontino-rails")
      od.locale = overrides.fetch(:locale, "it")
      yield od if block_given?
    end
  end

  it "stores the settings with their metrics" do
    configure { |od| od.metric("users.registered", label: "Users", group: "Users", type: :count) { 1 } }

    expect(described_class.settings.metrics.map(&:key)).to eq([ "users.registered" ])
    expect(described_class.settings).to be_enabled
  end

  it "is disabled when the token is blank" do
    expect(configure(token: "  ")).not_to be_enabled
    expect(configure(token: nil)).not_to be_enabled
  end

  it "rejects a duplicated key" do
    expect {
      configure do |od|
        od.metric("users.registered", label: "A", group: "Users", type: :count) { 1 }
        od.metric("users.registered", label: "B", group: "Users", type: :count) { 2 }
      end
    }.to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /duplicated/)
  end

  it "rejects more than 50 metrics" do
    expect {
      configure { |od| 51.times { |i| od.metric("users.m#{i}", label: "M", group: "G", type: :count) { 1 } } }
    }.to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /50/)
  end

  %i[name app locale].each do |field|
    it "requires #{field}" do
      expect { configure(field => "") }
        .to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /#{field}/)
    end
  end

  it "rejects a locale that is not a language code" do
    expect { configure(locale: "italian") }
      .to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /locale/)
  end

  it "keeps the previous settings when the new ones are invalid" do
    configure
    previous = described_class.settings

    expect { configure(name: "") }.to raise_error(CloseYourIt::OpenDashboard::ConfigurationError)
    expect(described_class.settings).to be(previous)
  end

  it "forgets everything on reset!" do
    configure
    described_class.reset!

    expect(described_class.settings).to be_nil
  end
end
