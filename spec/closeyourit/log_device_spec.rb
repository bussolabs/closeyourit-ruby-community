# frozen_string_literal: true

require "logger"

RSpec.describe CloseYourIt::LogDevice do
  subject(:logger) { described_class.new }

  before do
    allow(CloseYourIt).to receive(:emit_log)
    allow(CloseYourIt).to receive(:logs_active?).and_return(true)
  end

  it "info forwards the info level with attributes as data (root without source)" do
    logger.info("hi", user_id: 1)
    expect(CloseYourIt).to have_received(:emit_log).with("info", "hi", source: nil, attributes: { user_id: 1 })
  end

  it "warn maps to the warning level (backend enum)" do
    logger.warn("careful")
    expect(CloseYourIt).to have_received(:emit_log).with("warning", "careful", source: nil, attributes: {})
  end

  it "debug/error/fatal forward their respective level" do
    logger.debug("d")
    logger.error("e")
    logger.fatal("f")
    expect(CloseYourIt).to have_received(:emit_log).with("debug", "d", source: nil, attributes: {})
    expect(CloseYourIt).to have_received(:emit_log).with("error", "e", source: nil, attributes: {})
    expect(CloseYourIt).to have_received(:emit_log).with("fatal", "f", source: nil, attributes: {})
  end

  it "<< forwards as info" do
    logger << "streamed"
    expect(CloseYourIt).to have_received(:emit_log).with("info", "streamed", source: nil, attributes: {})
  end

  it "add maps the numeric severity (::Logger::ERROR → error)" do
    logger.add(::Logger::ERROR, "boom")
    expect(CloseYourIt).to have_received(:emit_log).with("error", "boom", source: nil, attributes: {})
  end

  it "evaluates the block as the message" do
    logger.info { "lazy" }
    expect(CloseYourIt).to have_received(:emit_log).with("info", "lazy", source: nil, attributes: {})
  end

  it "does NOT evaluate the block when logs are off (lazy)" do
    allow(CloseYourIt).to receive(:logs_active?).and_return(false)
    evaluated = false
    logger.debug { evaluated = true }
    expect(evaluated).to be(false)
    expect(CloseYourIt).not_to have_received(:emit_log)
  end

  describe "explicit log source (child logger, cross-SDK parity)" do
    it "named('x') forwards logs with that source, attributes stay data" do
      logger.named("payments").info("retry", attempt: 3)
      expect(CloseYourIt).to have_received(:emit_log).with("info", "retry", source: "payments", attributes: { attempt: 3 })
    end

    it "named returns a new LogDevice without mutating the root logger" do
      child = logger.named("payments")
      expect(child).to be_a(described_class)
      expect(child).not_to be(logger)

      logger.info("from root")
      expect(CloseYourIt).to have_received(:emit_log).with("info", "from root", source: nil, attributes: {})
    end

    it "the constructor accepts an explicit source" do
      described_class.new("billing").warn("slow")
      expect(CloseYourIt).to have_received(:emit_log).with("warning", "slow", source: "billing", attributes: {})
    end

    it "normalizes a blank/nil source to no source (nil)" do
      logger.named("").info("x")
      logger.named("   ").info("y")
      logger.named(nil).info("z")
      expect(CloseYourIt).to have_received(:emit_log).with("info", "x", source: nil, attributes: {})
      expect(CloseYourIt).to have_received(:emit_log).with("info", "y", source: nil, attributes: {})
      expect(CloseYourIt).to have_received(:emit_log).with("info", "z", source: nil, attributes: {})
    end

    it "normalizes a non-string source (symbol) to a string" do
      logger.named(:payments).info("x")
      expect(CloseYourIt).to have_received(:emit_log).with("info", "x", source: "payments", attributes: {})
    end
  end

  describe "protection of the 'logger' key in attributes (CYRB-8)" do
    it "a logger key passed to a method stays a data attribute and is not hijacked as the source" do
      logger.warn("disk full", logger: "/dev/sda1")
      expect(CloseYourIt).to have_received(:emit_log).with("warning", "disk full", source: nil, attributes: { logger: "/dev/sda1" })
    end

    it "source (named) and logger attribute coexist without colliding" do
      logger.named("payments").warn("disk full", logger: "/dev/sda1", disk: "sda1")
      expect(CloseYourIt).to have_received(:emit_log).with(
        "warning", "disk full", source: "payments", attributes: { logger: "/dev/sda1", disk: "sda1" }
      )
    end
  end
end
