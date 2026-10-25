# frozen_string_literal: true

require "bigdecimal"

RSpec.describe CloseYourIt::OpenDashboard::Metric do
  let(:now) { Time.utc(2026, 10, 25, 9, 30) }

  def build(key = "users.registered", **options, &block)
    defaults = { label: "Registered users", group: "Users", type: :count }
    described_class.new(key, **defaults, **options, &(block || ->(_since) { 1 }))
  end

  describe "#to_h" do
    it "passes the start of the period to the block and returns value, previous and period" do
      seen = nil
      metric = build { |since| seen = since; { value: 1240, previous: 1180 } }

      expect(metric.to_h(now)).to eq(
        key: "users.registered", label: "Registered users", group: "Users", type: "count",
        value: 1240, previous: 1180, period: "30d"
      )
      expect(seen).to eq(now - (30 * 86_400))
    end

    it "accepts a bare number as the value and leaves out previous and period" do
      expect(build { 7 }.to_h(now)).to eq(
        key: "users.registered", label: "Registered users", group: "Users", type: "count", value: 7
      )
    end

    it "includes currency for money and better when given" do
      metric = build("revenue.mrr", type: :money, currency: "EUR", better: :up, period: "7d") { 100 }

      expect(metric.to_h(now)).to include(type: "money", currency: "EUR", better: "up", value: 100)
    end

    it "reports a failing block as unavailable and sends the exception as handled" do
      error = RuntimeError.new("db down")
      expect(CloseYourIt).to receive(:capture_exception).with(error, handled: true)

      expect(build { raise error }.to_h(now)).to include(value: nil, error: "unavailable")
    end

    it "treats a non-numeric value as unavailable" do
      allow(CloseYourIt).to receive(:capture_exception)

      expect(build { "1240" }.to_h(now)).to include(value: nil, error: "unavailable")
    end

    it "treats a fractional count or money as unavailable" do
      allow(CloseYourIt).to receive(:capture_exception)

      expect(build { 12.5 }.to_h(now)).to include(value: nil, error: "unavailable")
    end

    it "keeps fractional values for percent" do
      expect(build("churn.rate", type: :percent) { 3.1 }.to_h(now)).to include(value: 3.1)
    end

    context "with non-finite, non-integral or out-of-range numbers" do
      before { allow(CloseYourIt).to receive(:capture_exception) }

      it "treats NaN percent as unavailable and reports it" do
        expect(CloseYourIt).to receive(:capture_exception).with(an_instance_of(TypeError), handled: true)

        expect(build("churn.rate", type: :percent) { Float::NAN }.to_h(now)).to include(value: nil, error: "unavailable")
      end

      it "treats infinite duration as unavailable" do
        expect(build("job.time", type: :duration) { Float::INFINITY }.to_h(now)).to include(value: nil, error: "unavailable")
      end

      it "treats a BigDecimal NaN as unavailable" do
        expect(build("churn.rate", type: :percent) { BigDecimal("NaN") }.to_h(now)).to include(error: "unavailable")
      end

      it "emits a whole BigDecimal count as an Integer" do
        value = build { BigDecimal("1240") }.to_h(now)[:value]

        expect(value).to eq(1240)
        expect(value).to be_a(Integer)
      end

      it "emits a BigDecimal percent as a Float" do
        value = build("churn.rate", type: :percent) { BigDecimal("3.1") }.to_h(now)[:value]

        expect(value).to eq(3.1)
        expect(value).to be_a(Float)
      end

      it "emits a Rational percent as a Float" do
        value = build("churn.rate", type: :percent) { Rational(1, 4) }.to_h(now)[:value]

        expect(value).to eq(0.25)
        expect(value).to be_a(Float)
      end

      it "emits a whole Float money as an Integer" do
        value = build("revenue.mrr", type: :money, currency: "EUR") { 1240.0 }.to_h(now)[:value]

        expect(value).to eq(1240)
        expect(value).to be_a(Integer)
      end

      it "treats a negative count as unavailable" do
        expect(build { -1 }.to_h(now)).to include(value: nil, error: "unavailable")
      end

      it "treats a percent above 100 as unavailable" do
        expect(build("churn.rate", type: :percent) { 103 }.to_h(now)).to include(value: nil, error: "unavailable")
      end

      it "treats a negative duration as unavailable" do
        expect(build("job.time", type: :duration) { -5 }.to_h(now)).to include(value: nil, error: "unavailable")
      end

      it "allows a negative money value" do
        expect(build("revenue.mrr", type: :money, currency: "EUR") { -500 }.to_h(now)).to include(value: -500)
      end

      it "treats a NaN previous as unavailable" do
        metric = build("churn.rate", type: :percent) { { value: 1.0, previous: Float::NAN } }

        expect(metric.to_h(now)).to include(value: nil, error: "unavailable")
      end
    end
  end

  describe "validation" do
    {
      "an uppercase key" => [ "Users.Registered", {} ],
      "a key without a dot" => [ "users", {} ],
      "a blank label" => [ "users.registered", { label: " " } ],
      "a blank group" => [ "users.registered", { group: "" } ],
      "an unknown type" => [ "users.registered", { type: :ratio } ],
      "money without currency" => [ "revenue.mrr", { type: :money } ],
      "money with a bad currency" => [ "revenue.mrr", { type: :money, currency: "eur" } ],
      "currency on a count" => [ "users.registered", { currency: "EUR" } ],
      "an unknown period" => [ "users.registered", { period: "2w" } ],
      "an unknown better" => [ "users.registered", { better: :sideways } ]
    }.each do |name, (key, options)|
      it "rejects #{name}" do
        expect { build(key, **options) }.to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /#{Regexp.escape(key)}/)
      end
    end

    it "rejects a metric without a block" do
      expect {
        described_class.new("users.registered", label: "Users", group: "Users", type: :count)
      }.to raise_error(CloseYourIt::OpenDashboard::ConfigurationError, /block/)
    end
  end
end
