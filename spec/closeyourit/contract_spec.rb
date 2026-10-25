# frozen_string_literal: true

require "digest"
require "json_schemer"

RSpec.describe "Ingest contract v1" do
  CONTRACT_ROOT = File.expand_path("../../contracts/ingest", __dir__)
  CONTRACT = File.join(CONTRACT_ROOT, "v1")

  def contract_json(relative)
    JSON.parse(File.read(File.join(CONTRACT, relative)))
  end

  def contract_validator(definition)
    schema = contract_json("schema.json")
    JSONSchemer.schema({
      "$schema" => schema.fetch("$schema"),
      "$ref" => "#/$defs/#{definition}",
      "$defs" => schema.fetch("$defs")
    })
  end

  it "matches the locked canonical snapshot and all checksums" do
    lock = JSON.parse(File.read(File.join(CONTRACT_ROOT, "LOCK.json")))
    sums = File.read(File.join(CONTRACT, "SHA256SUMS"))
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(File.join(CONTRACT, relative)).hexdigest).to eq(expected), relative
    end
  end

  it "applies the declared validity to every golden fixture" do
    contract_json("manifest.json").fetch("fixtures").each do |fixture|
      valid = contract_validator(fixture.fetch("definition")).valid?(contract_json(fixture.fetch("path")))
      expect(valid).to eq(fixture.fetch("valid")), fixture.fetch("path")
    end
  end

  it "validates the Ruby producers for events, logs and metrics" do
    configuration = CloseYourIt::Configuration.new.tap { |item| item.environment = "production" }
    payloads = {
      "event" => CloseYourIt::MessageEvent.new(
        "cache miss", level: "warning", configuration:
      ).to_h,
      "log" => CloseYourIt::LogEvent.new(
        "order charged", level: :info, attributes: {}, configuration:
      ).to_h,
      "slow_method" => CloseYourIt::SlowMethodEvent.new(
        "checkout.total", 12.345, nil, configuration
      ).to_h,
      "performance_issue" => CloseYourIt::JobMetricEvent.new(
        { subtype: "slow_job", duration_ms: 8123.4, job_class: "MailDeliveryJob",
          queue: "mailers", adapter: "active_job", attempt: 2, trace_id: "job-9" },
        configuration
      ).to_h
    }

    payloads.each do |definition, payload|
      errors = contract_validator(definition).validate(payload).to_a
      expect(errors).to be_empty, "#{definition}: #{errors.inspect}"
    end
  end

  it "consumes the whole HTTP matrix and classifies every outcome as 2xx or failed" do
    configuration = CloseYourIt::Configuration.new.tap do |item|
      item.endpoint_url = "https://closeyour.it"
      item.token = "cyi_contract"
    end
    transport = CloseYourIt::Transport.new(configuration)
    path = "/api/v1/projects/project/events"
    url = "https://closeyour.it#{path}"
    allow(CloseYourIt.internal_logger).to receive(:warn)
    allow(CloseYourIt.internal_logger).to receive(:error)

    contract_json("fixtures/http/cases.json").each do |contract_case|
      before = CloseYourIt.stats.to_h
      if contract_case["status"]
        stub_request(:post, url).to_return(status: contract_case.fetch("status"))
      else
        stub_request(:post, url).to_timeout
      end

      transport.send_event({}, path:)

      accepted = contract_case["status"]&.between?(200, 299)
      counter = accepted ? :sent : :failed
      expect(CloseYourIt.stats[counter] - before.fetch(counter)).to eq(1), contract_case.fetch("id")
    end
  end

  it "keeps the separation between bearer, public DSN and gateway explicit" do
    cases = contract_json("fixtures/http/auth-cases.json").to_h { |item| [ item.fetch("id"), item ] }

    expect(cases.dig("public-store", "credential")).to eq("public_dsn")
    expect(cases.dig("public-pageviews-rejected", "status")).to eq(401)
    expect(cases.dig("gateway-pageviews", "forward_to")).to start_with("/api/v1/projects/")
    expect(cases.dig("gateway-replays", "forward_to")).to start_with("/api/v1/projects/")
  end
end
