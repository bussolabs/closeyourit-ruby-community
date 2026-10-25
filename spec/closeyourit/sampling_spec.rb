# frozen_string_literal: true

RSpec.describe "Sampling, Regexp ignore and release detection" do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def boom
    raise "boom"
  rescue RuntimeError => e
    e
  end

  describe "sample_rate" do
    it "sends nothing at 0.0 (deterministic)" do
      enable!(sample_rate: 0.0)
      stub = stub_request(:post, url)
      CloseYourIt.capture_exception(boom)
      expect(stub).not_to have_been_requested
    end

    it "always sends at 1.0 (deterministic)" do
      enable!(sample_rate: 1.0)
      stub = stub_request(:post, url)
      CloseYourIt.capture_exception(boom)
      expect(stub).to have_been_requested
    end

    it "in between: sends when Random.rand < rate" do
      enable!(sample_rate: 0.5)
      allow(Random).to receive(:rand).and_return(0.4)
      stub = stub_request(:post, url)
      CloseYourIt.capture_exception(boom)
      expect(stub).to have_been_requested
    end

    it "in between: drops when Random.rand >= rate" do
      enable!(sample_rate: 0.5)
      allow(Random).to receive(:rand).and_return(0.6)
      stub = stub_request(:post, url)
      CloseYourIt.capture_exception(boom)
      expect(stub).not_to have_been_requested
    end
  end

  describe "exception ignore" do
    it "ignores by Regexp match on the class name" do
      stub_const("Payments::TimeoutError", Class.new(StandardError))
      enable!(excluded_exceptions: [ /Timeout/ ])
      stub = stub_request(:post, url)

      ex = (raise Payments::TimeoutError, "x" rescue $!) # rubocop:disable Style/RescueModifier
      CloseYourIt.capture_exception(ex)

      expect(stub).not_to have_been_requested
    end

    it "keeps the string match (backward compatible)" do
      stub_const("My::Err", Class.new(StandardError))
      enable!(excluded_exceptions: [ "My::Err" ])
      stub = stub_request(:post, url)

      ex = (raise My::Err, "x" rescue $!) # rubocop:disable Style/RescueModifier
      CloseYourIt.capture_exception(ex)

      expect(stub).not_to have_been_requested
    end

    it "sends non-excluded exceptions" do
      enable!(excluded_exceptions: [ /Timeout/ ])
      stub = stub_request(:post, url)
      CloseYourIt.capture_exception(boom)
      expect(stub).to have_been_requested
    end
  end

  describe "Configuration#excluded_exceptions= keeps Regexps" do
    subject(:config) { CloseYourIt::Configuration.new }

    it "converts Class/String to string and keeps Regexps" do
      config.excluded_exceptions = [ RuntimeError, "My::Error", /Timeout/ ]
      expect(config.excluded_exceptions).to eq([ "RuntimeError", "My::Error", /Timeout/ ])
    end
  end

  describe "Configuration#detect_release" do
    subject(:config) { CloseYourIt::Configuration.new }

    # Selective stub of ENV["key"] keeping the other reads real.
    def stub_env(pairs)
      allow(ENV).to receive(:[]).and_call_original
      pairs.each { |key, value| allow(ENV).to receive(:[]).with(key).and_return(value) }
    end

    it "uses KAMAL_VERSION when there is no tag" do
      stub_env("APP_GIT_TAG" => nil, "GIT_TAG" => nil, "KAMAL_VERSION" => "v1.2.3")
      expect(config.detect_release).to eq("v1.2.3")
    end

    it "falls back to git_revision when env and tag are absent" do
      stub_env("APP_GIT_TAG" => nil, "GIT_TAG" => nil, "KAMAL_VERSION" => nil,
               "GIT_SHA" => nil, "GIT_REVISION" => nil, "SOURCE_VERSION" => nil,
               "HEROKU_SLUG_COMMIT" => nil)
      allow(config).to receive(:git_revision).and_return("deadbee")
      expect(config.detect_release).to eq("deadbee")
    end

    it "prefers the APP_GIT_TAG semver tag to the KAMAL_VERSION short SHA" do
      stub_env("APP_GIT_TAG" => "v0.0.43", "KAMAL_VERSION" => "d3ce2af")
      expect(config.detect_release).to eq("v0.0.43")
    end

    it "uses GIT_TAG when APP_GIT_TAG is absent" do
      stub_env("APP_GIT_TAG" => nil, "GIT_TAG" => "v2.5.0", "KAMAL_VERSION" => "d3ce2af")
      expect(config.detect_release).to eq("v2.5.0")
    end

    it "accepts a valid prerelease tag" do
      stub_env("APP_GIT_TAG" => "v1.2.3-rc1", "KAMAL_VERSION" => "d3ce2af")
      expect(config.detect_release).to eq("v1.2.3-rc1")
    end

    [ "unknown", "", "   ", "main" ].each do |bad|
      it "ignores a non-semver APP_GIT_TAG (#{bad.inspect}) and falls back to the SHA chain" do
        stub_env("APP_GIT_TAG" => bad, "GIT_TAG" => nil, "KAMAL_VERSION" => "d3ce2af")
        expect(config.detect_release).to eq("d3ce2af")
      end
    end

    it "keeps the SHA chain unchanged without any tag" do
      stub_env("APP_GIT_TAG" => nil, "GIT_TAG" => nil, "KAMAL_VERSION" => nil,
               "GIT_SHA" => "cafe123")
      expect(config.detect_release).to eq("cafe123")
    end

    it "#release: an explicit CLOSEYOURIT_RELEASE takes precedence over tag and SHA" do
      config.release = "custom-release"
      stub_env("APP_GIT_TAG" => "v9.9.9", "KAMAL_VERSION" => "d3ce2af")
      expect(config.release).to eq("custom-release")
    end
  end
end
