# frozen_string_literal: true

# CYRB-47: a `rails runner` or a `rails console` is a person typing a one-off command, so its
# mistakes are the typist's, not the application's. On 2026-11-10 they were 36 groups closed by hand
# in a single day (culprits `p28.rb`, `np.rb`, `stdin`, e.g. `NameError: uninitialized constant
# Project`). Rake tasks and jobs are NOT in this family: scheduled work must stay monitored.
RSpec.describe CloseYourIt::ConsoleSession do
  describe ".active?" do
    it "is false in a normal process (web server, job worker)" do
      expect(described_class.active?).to be(false)
    end

    # Rails requires only the command file it is about to run (Rails::Command.lookup), so the
    # constant being defined means that command is the one running this process.
    it "is true under `rails runner`" do
      stub_const("Rails::Command::RunnerCommand", Class.new)

      expect(described_class.active?).to be(true)
    end

    it "is true under `rails console`" do
      stub_const("Rails::Command::ConsoleCommand", Class.new)

      expect(described_class.active?).to be(true)
    end

    it "is false under the other Rails commands (a rake task is scheduled work)" do
      stub_const("Rails::Command::RakeCommand", Class.new)

      expect(described_class.active?).to be(false)
    end
  end

  describe "CloseYourIt.capture_exception" do
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
      raise NameError, "uninitialized constant Project"
    rescue StandardError => e
      e
    end

    it "does not send the mistakes of a hand-typed command" do
      stub_const("Rails::Command::RunnerCommand", Class.new)
      configure!
      stub = stub_request(:post, url)

      CloseYourIt.capture_exception(sample_exception)

      expect(stub).not_to have_been_requested
    end

    # The runner wraps the code in the Rails executor, which reports the uncaught exception to
    # `Rails.error` (source "application.runner.railties") → the subscriber, not the Rack middleware.
    # That path must be silenced too, otherwise the fix would cover nothing.
    it "does not send them when they arrive through the Rails error reporter" do
      stub_const("Rails::Command::RunnerCommand", Class.new)
      configure!
      stub = stub_request(:post, url)

      CloseYourIt::Rails::ErrorSubscriber.new.report(
        sample_exception, handled: false, severity: :error, context: {},
        source: "application.runner.railties"
      )

      expect(stub).not_to have_been_requested
    end

    it "sends them when the app asks for them with capture_console_errors" do
      stub_const("Rails::Command::RunnerCommand", Class.new)
      configure!(capture_console_errors: true)
      stub = stub_request(:post, url)

      CloseYourIt.capture_exception(sample_exception)

      expect(stub).to have_been_requested.times(1)
    end

    it "keeps sending the errors of scheduled work (rake task, job)" do
      stub_const("Rails::Command::RakeCommand", Class.new)
      configure!
      stub = stub_request(:post, url)

      CloseYourIt.capture_exception(sample_exception)

      expect(stub).to have_been_requested.times(1)
    end
  end
end
