# frozen_string_literal: true

RSpec.describe CloseYourIt::Rails::CaptureExceptions do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  def enable!
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
    end
  end

  it "re-raises the exception and captures it as a Sentry event (level=error)" do
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { raise "kaboom" }

    expect { described_class.new(app).call({}) }.to raise_error(RuntimeError, "kaboom")

    expect(stub).to have_been_requested.times(1)
    expect(WebMock).to have_requested(:post, url).with { |req| JSON.parse(req.body)["level"] == "error" }
  end

  it "lets normal responses through without capturing" do
    app = ->(_env) { [ 200, {}, [ "ok" ] ] }

    expect(CloseYourIt).not_to receive(:capture_exception)
    expect(described_class.new(app).call({})).to eq([ 200, {}, [ "ok" ] ])
  end

  it "does not send excluded exceptions (e.g. RecordNotFound) but re-raises them" do
    stub_const("ActiveRecord::RecordNotFound", Class.new(StandardError))
    enable!
    stub = stub_request(:post, url)
    app = ->(_env) { raise ActiveRecord::RecordNotFound, "missing" }

    expect { described_class.new(app).call({}) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(stub).not_to have_been_requested
  end
end
