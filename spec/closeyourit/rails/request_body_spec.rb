# frozen_string_literal: true

require "stringio"

RSpec.describe CloseYourIt::Rails::RequestBody do
  before do
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
    end
  end

  def body_env(body, content_type:)
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    }
  end

  it "extracts the params of a urlencoded form body, scrubbed" do
    env = body_env("name=Anna&password=hunter2", content_type: "application/x-www-form-urlencoded")

    expect(described_class.extract(env)).to eq("name" => "Anna", "password" => "[FILTERED]")
  end

  # `email` is PII → redacted like in the backend (CYRB-3); a benign `title` survives.
  it "extracts and scrubs a JSON body (email is PII → redacted, CYRB-3)" do
    env = body_env('{"title":"Report","email":"a@b.it","api_key":"k-1"}', content_type: "application/json")

    expect(described_class.extract(env)).to eq(
      "title" => "Report", "email" => "[FILTERED]", "api_key" => "[FILTERED]"
    )
  end

  it "prefers the params already parsed by Rails without re-reading the body" do
    env = {
      "REQUEST_METHOD" => "POST",
      "action_dispatch.request.request_parameters" => { "q" => "ok", "password" => "x" }
    }

    expect(described_class.extract(env)).to eq("q" => "ok", "password" => "[FILTERED]")
  end

  it "replaces uploads with a [FILE] placeholder" do
    upload = double("UploadedFile", original_filename: "avatar.png")
    env = {
      "REQUEST_METHOD" => "POST",
      "action_dispatch.request.request_parameters" => { "avatar" => upload, "title" => "hello" }
    }

    data = described_class.extract(env)
    expect(data["avatar"]).to eq("[FILE: avatar.png]")
    expect(data["title"]).to eq("hello")
  end

  it "replaces non-serializable objects with a class placeholder" do
    env = {
      "REQUEST_METHOD" => "POST",
      "action_dispatch.request.request_parameters" => { "weird" => Object.new }
    }

    expect(described_class.extract(env)).to eq("weird" => "[OBJECT: Object]")
  end

  it "truncates string values beyond 1024 characters" do
    env = body_env({ note: "x" * 5000 }.to_json.to_s, content_type: "application/json")

    expect(described_class.extract(env)["note"].size).to be <= 1025
  end

  it "re-reads the body leaving it available to the app (rewind)" do
    raw = '{"a":1}'
    env = body_env(raw, content_type: "application/json")

    described_class.extract(env)
    expect(env["rack.input"].read).to eq(raw)
  end

  it "returns nil beyond the size cap" do
    env = body_env("a=1", content_type: "application/json")
    env["CONTENT_LENGTH"] = (described_class::MAX_BODY_BYTES + 1).to_s

    expect(described_class.extract(env)).to be_nil
  end

  it "returns nil for an unsupported content type" do
    expect(described_class.extract(body_env("<xml/>", content_type: "text/xml"))).to be_nil
  end

  it "does not raise on malformed JSON (returns nil)" do
    expect(described_class.extract(body_env("{nope", content_type: "application/json"))).to be_nil
  end

  it "returns nil without body or params" do
    expect(described_class.extract("REQUEST_METHOD" => "GET")).to be_nil
  end
end
