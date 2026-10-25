# frozen_string_literal: true

require "closeyourit/rails/query_source"

RSpec.describe CloseYourIt::Rails::QuerySource do
  def with_cleaner(frames)
    cleaner = instance_double("cleaner")
    allow(cleaner).to receive(:clean).and_return(frames)
    stub_const("Rails", instance_double("Rails", backtrace_cleaner: cleaner))
  end

  it "returns the first cleaned application frame, without the :in suffix" do
    with_cleaner([ "app/models/order.rb:42:in `find'", "app/controllers/x.rb:9" ])
    expect(described_class.from_caller([ "raw-backtrace" ])).to eq("app/models/order.rb:42")
  end

  it "keeps a frame that already has no :in" do
    with_cleaner([ "app/controllers/x.rb:9" ])
    expect(described_class.from_caller([ "raw" ])).to eq("app/controllers/x.rb:9")
  end

  it "returns nil when no application frame is left" do
    with_cleaner([])
    expect(described_class.from_caller([ "raw" ])).to be_nil
  end
end
