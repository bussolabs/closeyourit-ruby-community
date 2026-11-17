# frozen_string_literal: true

RSpec.describe "CloseYourIt.capture_exception" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  # async_threads: 0 → synchronous send, deterministic for WebMock.
  def configure!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |k, v| c.public_send("#{k}=", v) }
    end
  end

  def sample_exception
    raise "boom"
  rescue StandardError => e
    e
  end

  it "sends a Sentry event on the /events path (1 POST)" do
    configure!
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["level"] == "error" && body.dig("exception", "values").is_a?(Array)
    }
  end

  it "deduplicates the same exception (a single send)" do
    configure!
    stub = stub_request(:post, url)
    exception = sample_exception

    CloseYourIt.capture_exception(exception)
    CloseYourIt.capture_exception(exception)

    expect(stub).to have_been_requested.times(1)
  end

  # CYRB-35: the "already captured" mark used to be written ON the exception, and on a frozen one
  # that write raised FrozenError back into the app in place of its own error.
  describe "frozen exception" do
    def frozen_exception
      sample_exception.freeze
    end

    it "sends it without raising and without touching it" do
      configure!
      stub = stub_request(:post, url)
      exception = frozen_exception

      expect { CloseYourIt.capture_exception(exception) }.not_to raise_error

      expect(stub).to have_been_requested.times(1)
      expect(exception).to be_frozen
      expect(exception.instance_variables).to be_empty
    end

    it "sends a frozen exception whose backtrace was set before freezing, leaving it unchanged" do
      configure!
      stub = stub_request(:post, url)
      exception = RuntimeError.new("frozen with backtrace")
      exception.set_backtrace(caller_locations)
      backtrace = exception.backtrace.dup
      exception.freeze

      expect { CloseYourIt.capture_exception(exception) }.not_to raise_error

      expect(stub).to have_been_requested.times(1)
      expect(WebMock).to have_requested(:post, url).with { |req|
        value = JSON.parse(req.body).dig("exception", "values").last
        value["value"] == "frozen with backtrace" && value.dig("stacktrace", "frames").size == backtrace.size
      }
      expect(exception).to be_frozen
      expect(exception.message).to eq("frozen with backtrace")
      expect(exception.backtrace).to eq(backtrace)
      expect(exception.instance_variables).to be_empty
    end

    # Frozen while in flight, captured, then re-raised by the app. Re-raising a frozen error that has a
    # backtrace makes Ruby itself raise an unfrozen copy (no gem involved), so identity cannot hold
    # here: what must hold is that the app gets its own error back, backtrace intact, never the gem's.
    it "lets the app re-raise its own frozen error with the backtrace intact" do
      configure!
      stub = stub_request(:post, url)
      backtrace = nil

      reraise = lambda do
        raise "frozen boom"
      rescue StandardError => e
        backtrace = e.freeze.backtrace
        CloseYourIt.capture_exception(e)
        raise
      end

      expect { reraise.call }.to raise_error(RuntimeError, "frozen boom") { |error|
        expect(error.backtrace).to eq(backtrace)
      }
      expect(backtrace).not_to be_empty
      expect(stub).to have_been_requested.times(1)
    end

    it "deduplicates the same frozen exception (a single send)" do
      configure!
      stub = stub_request(:post, url)
      exception = frozen_exception

      CloseYourIt.capture_exception(exception)
      CloseYourIt.capture_exception(exception)

      expect(stub).to have_been_requested.times(1)
    end
  end

  it "deduplicates by identity: two equal but distinct exceptions are both sent" do
    configure!
    stub = stub_request(:post, url)
    first = RuntimeError.new("same")
    second = RuntimeError.new("same")
    expect(first).to eq(second) # Exception#== compares class + message + backtrace

    CloseYourIt.capture_exception(first)
    CloseYourIt.capture_exception(second)

    expect(stub).to have_been_requested.times(2)
  end

  # CYRB-35: a fault of the gem while preparing the report must never replace the app's error.
  describe "internal fault while capturing" do
    let(:diagnostics) { [] }
    let(:logger) { instance_double(Logger, error: nil, warn: nil) }

    before do
      configure!(on_diagnostic: ->(event, details) { diagnostics << [ event, details ] })
      CloseYourIt.internal_logger = logger
    end

    after { CloseYourIt.internal_logger = nil }

    it "absorbs it, logs it and counts it as a drop with reason :error" do
      stub = stub_request(:post, url)
      allow(CloseYourIt::ErrorEvent).to receive(:from_exception).and_raise(NoMethodError, "gem bug")

      result = nil
      expect { result = CloseYourIt.capture_exception(sample_exception) }.not_to raise_error

      expect(result).to be_nil
      expect(stub).not_to have_been_requested
      expect(logger).to have_received(:error).with(/capture_exception: NoMethodError: gem bug/)
      expect(CloseYourIt.stats[:dropped]).to eq(1)
      expect(diagnostics).to include([ :drop, { reason: :error, error: "NoMethodError" } ])
    end

    it "absorbs a fault raised by the exception itself (a broken #message)" do
      stub = stub_request(:post, url)
      broken = Class.new(StandardError) do
        def message
          raise ArgumentError, "broken message"
        end
      end
      configure!(excluded_exceptions: [ /never/ ], on_diagnostic: ->(event, details) { diagnostics << [ event, details ] })

      expect { CloseYourIt.capture_exception(broken.new) }.not_to raise_error

      expect(stub).not_to have_been_requested
      expect(logger).to have_received(:error).with(/ArgumentError: broken message/)
    end
  end

  it "does not send exceptions in excluded_exceptions" do
    stub_const("Ignored::Boring", Class.new(StandardError))
    configure!(excluded_exceptions: [ "Ignored::Boring" ])
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(Ignored::Boring.new("nope"))

    expect(stub).not_to have_been_requested
  end

  it "does not send when before_send returns nil" do
    configure!(before_send: ->(_payload) { nil })
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).not_to have_been_requested
  end

  it "is a no-op without project_id" do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = nil
      c.async_threads = 0
    end
    stub = stub_request(:post, url)

    CloseYourIt.capture_exception(sample_exception)

    expect(stub).not_to have_been_requested
  end
end
