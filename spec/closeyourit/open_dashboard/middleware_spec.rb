# frozen_string_literal: true

require "json"
require_relative "../../support/open_dashboard_contract"

RSpec.describe CloseYourIt::OpenDashboard::Middleware do
  let(:downstream) { ->(_env) { [ 404, { "content-type" => "text/plain" }, [ "app" ] ] } }
  let(:middleware) { described_class.new(downstream) }

  def configure(token)
    CloseYourIt::OpenDashboard.configure do |od|
      od.token = token
      od.name = "scontino"
      od.app = "scontino-rails"
      od.locale = "it"
      od.metric("users.registered", label: "Utenti", group: "Utenti", type: :count) { 1240 }
    end
  end

  def env_for(method: "GET", path: "/open-dashboard", authorization: nil)
    { "REQUEST_METHOD" => method, "PATH_INFO" => path, "HTTP_AUTHORIZATION" => authorization }.compact
  end

  OpenDashboardContract.json("fixtures/http/cases.json").each do |kase|
    it "answers #{kase.fetch('status')} for the contract case #{kase.fetch('id')}" do
      configure(kase.fetch("configured_token"))
      request = kase.fetch("request")

      status, = middleware.call(env_for(method: request.fetch("method"), path: request.fetch("path"),
                                        authorization: request.fetch("authorization")))

      expect(status).to eq(kase.fetch("status"))
    end
  end

  it "returns a no-store JSON body valid against contract v1" do
    configure("od_live_example")

    status, headers, body = middleware.call(env_for(authorization: "Bearer od_live_example"))

    expect(status).to eq(200)
    expect(headers).to eq("content-type" => "application/json", "cache-control" => "no-store")
    expect(OpenDashboardContract.validator.validate(JSON.parse(body.join)).to_a).to eq([])
  end

  it "returns an empty 401 that does not say what is wrong" do
    configure("od_live_example")

    expect(middleware.call(env_for(authorization: "Bearer nope"))).to eq([ 401, { "cache-control" => "no-store" }, [] ])
  end

  it "rejects a token sent without the Bearer scheme" do
    configure("od_live_example")

    status, = middleware.call(env_for(authorization: "od_live_example"))

    expect(status).to eq(401)
  end

  it "hands the request to the app when the service never configured the dashboard" do
    status, _, body = middleware.call(env_for(authorization: "Bearer od_live_example"))

    expect([ status, body ]).to eq([ 404, [ "app" ] ])
  end

  it "hands other paths and methods to the app" do
    configure("od_live_example")

    expect(middleware.call(env_for(path: "/up")).first).to eq(404)
    expect(middleware.call(env_for(method: "POST", authorization: "Bearer od_live_example")).last).to eq([ "app" ])
  end
end
