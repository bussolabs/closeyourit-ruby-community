# frozen_string_literal: true

RSpec.describe CloseYourIt::TraceContext do
  # Reference valid traceparent (version 00): trace-id 32 hex, parent-id 16 hex, flag 01 (sampled).
  let(:trace_id)  { "4bf92f3577b34da6a3ce929d0e0e4736" }
  let(:parent_id) { "00f067aa0ba902b7" }
  let(:valid)     { "00-#{trace_id}-#{parent_id}-01" }

  describe ".parse" do
    it "adopts a valid traceparent keeping trace-id, parent-id and flags" do
      context = described_class.parse(valid)

      expect(context.trace_id).to eq(trace_id)
      expect(context.parent_id).to eq(parent_id)
      expect(context.flags).to eq(1)
      expect(context.sampled?).to be(true)
    end

    it "keeps the non-sampled flag (00 stays unsampled)" do
      context = described_class.parse("00-#{trace_id}-#{parent_id}-00")
      expect(context.sampled?).to be(false)
    end

    it "ignores spaces around the header" do
      expect(described_class.parse("  #{valid}  ").trace_id).to eq(trace_id)
    end

    it "returns nil for a nil or empty header" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("")).to be_nil
    end

    it "returns nil for wrong field lengths" do
      expect(described_class.parse("00-abc-#{parent_id}-01")).to be_nil
      expect(described_class.parse("00-#{trace_id}-abc-01")).to be_nil
    end

    it "returns nil for non-hex characters" do
      expect(described_class.parse("00-#{"z" * 32}-#{parent_id}-01")).to be_nil
    end

    it "returns nil for an all-zero trace-id or parent-id (invalid per W3C)" do
      expect(described_class.parse("00-#{"0" * 32}-#{parent_id}-01")).to be_nil
      expect(described_class.parse("00-#{trace_id}-#{"0" * 16}-01")).to be_nil
    end

    it "returns nil for the forbidden version ff" do
      expect(described_class.parse("ff-#{trace_id}-#{parent_id}-01")).to be_nil
    end

    it "returns nil if version 00 has extra fields (it must be exact)" do
      expect(described_class.parse("#{valid}-extra")).to be_nil
    end

    it "adopts future versions ignoring extra fields (forward-compat)" do
      context = described_class.parse("01-#{trace_id}-#{parent_id}-01-future")
      expect(context.trace_id).to eq(trace_id)
    end

    describe "tracestate" do
      it "keeps valid members in the original order" do
        context = described_class.parse(valid, "vendora=t61rcWkgMzE,vendorb=00f067aa0ba902b7")
        expect(context.tracestate).to eq("vendora=t61rcWkgMzE,vendorb=00f067aa0ba902b7")
      end

      it "drops malformed members and keeps the valid ones" do
        context = described_class.parse(valid, "vendora=ok, ,broken, vendorb=pure")
        expect(context.tracestate).to eq("vendora=ok,vendorb=pure")
      end

      it "returns nil if no member is valid" do
        expect(described_class.parse(valid, "broken,,pure-garbage").tracestate).to be_nil
      end

      it "caps at 32 members (W3C cap)" do
        many = (1..40).map { |i| "k#{i}=v#{i}" }.join(",")
        expect(described_class.parse(valid, many).tracestate.split(",").size).to eq(32)
      end

      it "stays nil when tracestate is absent" do
        expect(described_class.parse(valid).tracestate).to be_nil
      end
    end
  end

  describe ".generate" do
    it "generates a valid root context, sampled by default" do
      context = described_class.generate

      expect(context.trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(context.parent_id).to match(/\A[0-9a-f]{16}\z/)
      expect(context.sampled?).to be(true)
      expect(context.tracestate).to be_nil
    end

    it "generates distinct trace-ids on every call" do
      expect(described_class.generate.trace_id).not_to eq(described_class.generate.trace_id)
    end

    it "honors sampled: false" do
      expect(described_class.generate(sampled: false).sampled?).to be(false)
    end
  end

  describe "#traceparent" do
    it "serializes in W3C version 00 form" do
      expect(described_class.parse(valid).traceparent).to eq(valid)
    end

    it "formats flags as two hex digits" do
      expect(described_class.parse("00-#{trace_id}-#{parent_id}-00").traceparent).to end_with("-00")
    end
  end

  describe "#headers" do
    it "includes traceparent and tracestate when present" do
      context = described_class.parse(valid, "vendora=ok")
      expect(context.headers).to eq("traceparent" => valid, "tracestate" => "vendora=ok")
    end

    it "omits tracestate when absent" do
      expect(described_class.parse(valid).headers).to eq("traceparent" => valid)
    end

    it "never emits the baggage header (internal context/PII stays inside the boundary)" do
      expect(described_class.parse(valid, "vendora=ok").headers).not_to have_key("baggage")
    end
  end
end
