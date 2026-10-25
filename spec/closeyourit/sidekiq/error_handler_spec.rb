# frozen_string_literal: true

RSpec.describe CloseYourIt::Sidekiq::ErrorHandler do
  subject(:handler) { described_class.new }

  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/events" }

  def enable!
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
    end
  end

  def error
    raise "sidekiq boom"
  rescue RuntimeError => e
    e
  end

  it "captures the job error with job.* tags and resets the scope" do
    enable!
    stub_request(:post, url)
    context = { job: { "class" => "MailJob", "queue" => "default", "jid" => "abc123" } }

    handler.call(error, context)

    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body.dig("tags", "job.class") == "MailJob" && body.dig("tags", "job.queue") == "default"
    }
    expect(CloseYourIt::Scope.current.to_event_hash).to eq({})
  end

  it "does not raise when the context has no job" do
    enable!
    stub_request(:post, url)
    expect { handler.call(error, {}) }.not_to raise_error
  end
end
