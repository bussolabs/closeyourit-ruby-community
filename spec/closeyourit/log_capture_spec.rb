# frozen_string_literal: true

RSpec.describe "CloseYourIt.log (structured logging)" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/logs" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.logs_batch_size = 2
      c.logs_flush_interval = 0 # no timer in tests: flush only on batch or manually
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  after { CloseYourIt.clear_scope }

  it "flushes at batch_size sending an ARRAY to /logs" do
    enable! # batch_size 2
    stub = stub_request(:post, url)

    CloseYourIt.log(:info, "one")
    expect(stub).not_to have_been_requested # 1 < 2: not yet

    CloseYourIt.log(:warning, "two")
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body.is_a?(Array) && body.size == 2 &&
        body[0]["message"] == "one" && body[1]["level"] == "warning"
    }
  end

  it "a manual flush sends what is buffered (under batch_size)" do
    enable!(logs_batch_size: 50)
    stub_request(:post, url)

    CloseYourIt.log(:info, "pending")
    CloseYourIt.flush_logs

    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["message"] == "pending" }
  end

  it "includes the scrubbed attributes" do
    enable!(logs_batch_size: 1)
    stub_request(:post, url)

    CloseYourIt.log(:error, "boom", password: "x", ok: "v")

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body).first["attributes"] == { "password" => "[FILTERED]", "ok" => "v" }
    }
  end

  it "is a no-op when the gem is disabled" do
    stub = stub_request(:post, url)
    CloseYourIt.log(:info, "x")
    CloseYourIt.flush_logs
    expect(stub).not_to have_been_requested
  end

  it "honors logs_enabled = false" do
    enable!(logs_enabled: false, logs_batch_size: 1)
    stub = stub_request(:post, url)
    CloseYourIt.log(:info, "x")
    expect(stub).not_to have_been_requested
  end

  it "does not send with logs_sample_rate = 0" do
    enable!(logs_sample_rate: 0.0, logs_batch_size: 1)
    stub = stub_request(:post, url)
    CloseYourIt.log(:info, "x")
    expect(stub).not_to have_been_requested
  end

  it "normalizes the :warn level to warning (avoids downgrade to info on the backend)" do
    enable!(logs_batch_size: 1)
    stub_request(:post, url)
    CloseYourIt.log(:warn, "x")
    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["level"] == "warning" }
  end

  it "supports an explicit logger separate from the attributes" do
    enable!(logs_batch_size: 1)
    stub_request(:post, url)
    CloseYourIt.log(:info, "x", logger: "payments", k: "v")
    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body).first
      body["logger"] == "payments" && body["attributes"] == { "k" => "v" }
    }
  end

  describe "gating by logs_min_level (cross-SDK parity: standardize, not adapt)" do
    it "drops logs below the default :info threshold (debug not sent)" do
      enable!(logs_batch_size: 1)
      stub = stub_request(:post, url)
      CloseYourIt.log(:debug, "huge dump", payload: "huge")
      CloseYourIt.flush_logs
      expect(stub).not_to have_been_requested
    end

    it "sends logs at the threshold level (info == :info)" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)
      CloseYourIt.log(:info, "ok")
      expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["level"] == "info" }
    end

    it "sends logs above the threshold (warning > :info)" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)
      CloseYourIt.log(:warning, "careful")
      expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["level"] == "warning" }
    end

    # X-1 / X / X+1 boundary on the threshold, with logs_min_level raised to :warn.
    it "with logs_min_level=:warn drops info (below), sends warning (at) and error (above)" do
      enable!(logs_min_level: :warn, logs_batch_size: 1)
      stub = stub_request(:post, url)

      CloseYourIt.log(:info, "below") # severity 1 < 2 → dropped
      CloseYourIt.flush_logs
      expect(stub).not_to have_been_requested

      CloseYourIt.log(:warning, "at") # severity 2 == 2 → sent
      expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["message"] == "at" }

      CloseYourIt.log(:error, "above") # severity 3 > 2 → sent
      expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["message"] == "above" }
    end

    it "applies the threshold to CloseYourIt.logger.debug too (::Logger-like interface)" do
      enable!(logs_batch_size: 1)
      stub = stub_request(:post, url)
      CloseYourIt.logger.debug("huge dump", payload: "huge")
      CloseYourIt.flush_logs
      expect(stub).not_to have_been_requested
    end

    it "normalizes the level alias before comparing (min :warn, log :warn → sent)" do
      enable!(logs_min_level: :warn, logs_batch_size: 1)
      stub_request(:post, url)
      CloseYourIt.log(:warn, "x") # warn→warning (2) == warning (2) → sent
      expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body).first["level"] == "warning" }
    end
  end

  # CYRB-8: log source consistent across SDKs + protection of the `logger` attribute key.
  describe "log source and 'logger' key in attributes (CYRB-8)" do
    it "CloseYourIt.logger.named('payments') sets the source, attributes stay data" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)

      CloseYourIt.logger.named("payments").info("retry", attempt: 3)

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body).first
        body["logger"] == "payments" && body["attributes"] == { "attempt" => 3 }
      }
    end

    it "a 'logger' attribute is NOT hijacked as the source on the root logger (it stays in attributes)" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)

      CloseYourIt.logger.warn("disk full", logger: "/dev/sda1")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body).first
        body["attributes"] == { "logger" => "/dev/sda1" } && !body.key?("logger")
      }
    end

    it "source (named) and 'logger' attribute coexist without colliding" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)

      CloseYourIt.logger.named("payments").warn("disk full", logger: "/dev/sda1", disk: "sda1")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body).first
        body["logger"] == "payments" &&
          body["attributes"] == { "logger" => "/dev/sda1", "disk" => "sda1" }
      }
    end

    it "named returns a child logger without mutating the root logger" do
      enable!(logs_batch_size: 1)
      stub_request(:post, url)

      root = CloseYourIt.logger
      root.named("payments") # creates the child, must not touch the root
      root.info("from root")

      expect(WebMock).to have_requested(:post, url).with { |req|
        body = JSON.parse(req.body).first
        body["message"] == "from root" && !body.key?("logger")
      }
    end
  end

  # CYRB-17: exclusions gate the automatic Rails.logger MIRROR, not this method. Whoever writes
  # `CloseYourIt.log` has already decided they want that line: silencing it because it names a class
  # in the list would be a log that disappears without explanation. The boundary lives in LogBroadcast#add.
  it "does not apply exclusions to a log written on purpose" do
    enable!(logs_batch_size: 1)
    stub_request(:post, url)

    # `ActionController::RoutingError` is in the default exclusions: the broadcast would drop it.
    CloseYourIt.log(:error, "expected: ActionController::RoutingError handled by hand")

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body).first["message"].include?("ActionController::RoutingError")
    }
  end
end
