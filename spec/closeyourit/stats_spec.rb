# frozen_string_literal: true

RSpec.describe CloseYourIt::Stats do
  subject(:stats) { described_class.new }

  it "starts at zero on every counter" do
    expect(stats.to_h).to eq(enqueued: 0, dropped: 0, sent: 0, failed: 0, timeout: 0)
  end

  it "increments and returns the new value" do
    expect(stats.increment(:sent)).to eq(1)
    expect(stats.increment(:sent)).to eq(2)
    expect(stats[:sent]).to eq(2)
  end

  it "keeps independent counters" do
    stats.increment(:enqueued)
    stats.increment(:failed)
    expect(stats.to_h).to eq(enqueued: 1, dropped: 0, sent: 0, failed: 1, timeout: 0)
  end

  it "counts timeouts separately from generic failures" do
    stats.increment(:timeout)
    expect(stats[:timeout]).to eq(1)
    expect(stats.to_h).to include(timeout: 1, failed: 0)
  end

  it "resets with reset!" do
    stats.increment(:dropped)
    expect(stats.reset!.to_h).to eq(enqueued: 0, dropped: 0, sent: 0, failed: 0, timeout: 0)
  end

  it "exposes a thread-safe snapshot equal to to_h" do
    stats.increment(:sent)
    stats.increment(:timeout)
    expect(stats.snapshot).to eq(stats.to_h)
    expect(stats.snapshot).to eq(enqueued: 0, dropped: 0, sent: 1, failed: 0, timeout: 1)
  end

  it "raises on an unknown counter" do
    expect { stats.increment(:nope) }.to raise_error(KeyError)
  end

  it "counts correctly from concurrent threads" do
    threads = Array.new(10) { Thread.new { 100.times { stats.increment(:sent) } } }
    threads.each(&:join)
    expect(stats[:sent]).to eq(1_000)
  end
end
