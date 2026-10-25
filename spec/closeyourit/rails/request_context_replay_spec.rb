# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::RequestContext, "session replay correlation" do
  def enable!(**over)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def capture_replay_via(cookie)
    captured = :unset
    app = lambda do |_e|
      captured = CloseYourIt::Scope.current.replay_session_id
      [ 200, {}, [] ]
    end
    env = {
      "REQUEST_METHOD" => "GET", "rack.url_scheme" => "https",
      "HTTP_HOST" => "app.test", "PATH_INFO" => "/x"
    }
    env["HTTP_COOKIE"] = cookie unless cookie.nil?
    described_class.new(app).call(env)
    captured
  end

  it "extracts cyi_replay from the cookie and puts it on the scope" do
    enable!
    expect(capture_replay_via("cyi_replay=sess-1; other=x")).to eq("sess-1")
  end

  it "returns nil when the cookie has no cyi_replay" do
    enable!
    expect(capture_replay_via("session=abc")).to be_nil
  end

  it "returns nil when there is no cookie" do
    enable!
    expect(capture_replay_via(nil)).to be_nil
  end

  it "returns nil when cyi_replay is empty" do
    enable!
    expect(capture_replay_via("cyi_replay=; session=abc")).to be_nil
  end
end
