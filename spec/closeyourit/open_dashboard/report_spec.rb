# frozen_string_literal: true

require "bigdecimal"
require "json"
require_relative "../../support/open_dashboard_contract"

RSpec.describe CloseYourIt::OpenDashboard::Report do
  let(:now) { Time.utc(2026, 10, 25, 9, 30) }

  let(:settings) do
    CloseYourIt::OpenDashboard.configure do |od|
      od.token = "od_live_example"
      od.name = "scontino"
      od.app = "scontino-rails"
      od.url = "https://scontino.it"
      od.locale = "it"
      od.metric("users.registered", label: "Utenti registrati", group: "Utenti", type: :count) do
        { value: 1240, previous: 1180 }
      end
      od.metric("revenue.mrr", label: "Incasso", group: "Incassi", type: :money, currency: "EUR") { 428_000 }
      od.metric("subscriptions.churn_rate", label: "Persi", group: "Abbonamenti", type: :percent, better: :down) do
        raise "boom"
      end
    end
  end

  around do |example|
    saved = ENV.to_h.slice("APP_GIT_TAG", "APP_GIT_SHA", "CLOSEYOURIT_ENVIRONMENT")
    ENV["APP_GIT_TAG"] = "v1.4.2"
    ENV["APP_GIT_SHA"] = "a3f91c2d0e5b"
    ENV["CLOSEYOURIT_ENVIRONMENT"] = "production"
    example.run
  ensure
    %w[APP_GIT_TAG APP_GIT_SHA CLOSEYOURIT_ENVIRONMENT].each { |name| ENV.delete(name) }
    ENV.update(saved)
  end

  before { allow(CloseYourIt).to receive(:capture_exception) }

  it "describes the service with the same identity as /version" do
    report = described_class.new(settings, now:).to_h

    expect(report).to include(open_dashboard: "1.0", locale: "it", generated_at: "2026-10-25T09:30:00Z")
    expect(report[:service]).to eq(
      name: "scontino", app: "scontino-rails", version: "v1.4.2", sha: "a3f91c2",
      environment: "production", url: "https://scontino.it"
    )
  end

  it "lists the metrics in declaration order, a broken one included" do
    keys = described_class.new(settings, now:).to_h[:metrics].map { |metric| metric[:key] }

    expect(keys).to eq(%w[users.registered revenue.mrr subscriptions.churn_rate])
  end

  it "falls back to unknown when the build did not inject tag and sha" do
    ENV.delete("APP_GIT_TAG")
    ENV.delete("APP_GIT_SHA")

    expect(described_class.new(settings, now:).to_h[:service]).to include(version: "unknown", sha: "unknown")
  end

  it "leaves out url when the service does not set it" do
    settings.url = nil

    expect(described_class.new(settings, now:).to_h[:service]).not_to have_key(:url)
  end

  it "produces a response valid against contract v1" do
    payload = JSON.parse(JSON.generate(described_class.new(settings, now:).to_h))

    expect(OpenDashboardContract.validator.validate(payload).to_a).to eq([])
  end

  it "serialises non-finite and BigDecimal results into a contract-valid response" do
    risky = CloseYourIt::OpenDashboard.configure do |od|
      od.token = "od_live_example"
      od.name = "scontino"
      od.app = "scontino-rails"
      od.locale = "it"
      od.metric("churn.rate", label: "Churn", group: "Subscriptions", type: :percent) { Float::NAN }
      od.metric("users.registered", label: "Users", group: "Users", type: :count) { BigDecimal("1240") }
    end

    json = nil
    expect { json = JSON.generate(described_class.new(risky, now:).to_h) }.not_to raise_error
    expect(OpenDashboardContract.validator.validate(JSON.parse(json)).to_a).to eq([])
  end
end
