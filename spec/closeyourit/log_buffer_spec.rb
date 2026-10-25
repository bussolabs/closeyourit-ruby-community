# frozen_string_literal: true

RSpec.describe CloseYourIt::LogBuffer do
  let(:client) { instance_double(CloseYourIt::Client, flush_logs: nil) }
  let(:configuration) do
    instance_double(CloseYourIt::Configuration, logs_batch_size: 3, logs_flush_interval: 0)
  end

  subject(:buffer) { described_class.new(client: client, configuration: configuration) }

  it "flushes when it reaches logs_batch_size" do
    buffer.add(:a)
    buffer.add(:b)
    expect(client).not_to have_received(:flush_logs)

    buffer.add(:c)
    expect(client).to have_received(:flush_logs).with(%i[a b c])
  end

  it "a manual flush sends the partial buffer and empties it" do
    buffer.add(:a)
    buffer.flush
    expect(client).to have_received(:flush_logs).with(%i[a])

    buffer.flush # now empty → no-op
    expect(client).to have_received(:flush_logs).once
  end

  it "does not flush an empty buffer" do
    buffer.flush
    expect(client).not_to have_received(:flush_logs)
  end

  it "shutdown flushes what is left" do
    buffer.add(:a)
    buffer.shutdown
    expect(client).to have_received(:flush_logs).with(%i[a])
  end

  it "flush swallows a flush_logs error without propagating (request and timer threads stay alive)" do
    allow(client).to receive(:flush_logs).and_raise(RuntimeError, "boom")
    buffer.add(:a)
    expect { buffer.flush }.not_to raise_error
  end

  it "counts the whole lost batch as dropped when flush_logs raises (CYRB-12)" do
    allow(client).to receive(:flush_logs).and_raise(RuntimeError, "boom")
    allow(CloseYourIt.internal_logger).to receive(:error)
    buffer.add(:a)
    buffer.add(:b)

    # The batch has already been drained from the buffer: if flush_logs raises those logs are lost → made visible.
    expect { buffer.flush }.to change { CloseYourIt.stats[:dropped] }.by(2)
  end

  describe "periodic flush timer" do
    let(:configuration) do
      instance_double(CloseYourIt::Configuration, logs_batch_size: 100, logs_flush_interval: 7)
    end

    it "sets up a TimerTask with execution_interval = logs_flush_interval" do
      buffer.add(:a)
      expect(buffer.timer).to be_a(Concurrent::TimerTask)
      expect(buffer.timer.execution_interval).to eq(7)
    ensure
      buffer.timer&.shutdown
    end
  end
end
