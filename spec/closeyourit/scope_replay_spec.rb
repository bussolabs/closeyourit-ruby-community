# frozen_string_literal: true

RSpec.describe CloseYourIt::Scope, "session replay" do
  before do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
    end
  end

  it "emits contexts.replay.replay_id when replay_session_id is set" do
    scope = described_class.new
    scope.replay_session_id = "sess-9"
    expect(scope.to_event_hash.dig("contexts", "replay", "replay_id")).to eq("sess-9")
  end

  it "does not add contexts.replay without replay_session_id" do
    scope = described_class.new
    expect(scope.to_event_hash["contexts"]).to be_nil
  end

  it "coexists with user contexts without overwriting them" do
    scope = described_class.new
    scope.set_context("os", { name: "Linux" })
    scope.replay_session_id = "sess-9"

    contexts = scope.to_event_hash["contexts"]
    expect(contexts.dig("os", "name")).to eq("Linux")
    expect(contexts.dig("replay", "replay_id")).to eq("sess-9")
  end

  it "clear resets replay_session_id" do
    scope = described_class.new
    scope.replay_session_id = "sess-9"
    scope.clear
    expect(scope.replay_session_id).to be_nil
  end
end
