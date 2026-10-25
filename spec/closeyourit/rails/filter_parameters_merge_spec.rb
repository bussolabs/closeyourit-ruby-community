# frozen_string_literal: true

# CYRB-28 — keys the host app already declared sensitive via `Rails.application.config.filter_parameters`
# must be scrubbed by the gem without repeating them in `config.filter_parameters`. The railtie merges
# them after the config initializers (CloseYourIt.init runs there and would otherwise overwrite the
# list). Railties are not loaded in this suite, so the merge lives on the Configuration and the railtie
# wiring is checked at source level (same approach as the CYRB-7 spec).
RSpec.describe "CYRB-28 — Rails filter_parameters merged into the gem configuration" do
  let(:railtie_source) do
    File.read(File.expand_path("../../../lib/closeyourit/rails/railtie.rb", __dir__))
  end

  let(:config) { CloseYourIt::Configuration.new }

  it "merges strings, symbols and regexps keeping the keys set explicitly on the gem" do
    config.filter_parameters = [ "badge" ]
    config.merge_filter_parameters([ :tax_code, "passw", /otp/i ])

    expect(config.filter_parameters).to eq([ "badge", :tax_code, "passw", /otp/i ])
  end

  it "does not duplicate keys already present" do
    config.filter_parameters = [ "badge" ]
    config.merge_filter_parameters([ "badge", :tax_code ])

    expect(config.filter_parameters).to eq([ "badge", :tax_code ])
  end

  it "drops Rails filter procs (they mutate the value in place, the Scrubber matches keys only)" do
    config.merge_filter_parameters([ :tax_code, ->(_key, _value) { } ])

    expect(config.filter_parameters).to eq([ :tax_code ])
  end

  it "scrubs a key declared sensitive by Rails in params and tags" do
    config.merge_filter_parameters([ :tax_code ])
    scrubber = CloseYourIt::Scrubber.new(config)

    expect(scrubber.filter_params("tax_code" => "RSSMRA80A01H501U", "city" => "Rimini"))
      .to eq("tax_code" => "[FILTERED]", "city" => "Rimini")
    expect(scrubber.filter_value(:tax_code, "x")).to eq("[FILTERED]")
  end

  it "the railtie merges Rails.application.config.filter_parameters after the config initializers" do
    expect(railtie_source).to match(
      /initializer "closeyourit\.merge_rails_filter_parameters", after: :load_config_initializers do \|app\|\s+CloseYourIt\.configuration\.merge_filter_parameters\(app\.config\.filter_parameters\)/
    )
  end
end
