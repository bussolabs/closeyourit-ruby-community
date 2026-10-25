# frozen_string_literal: true

RSpec.describe CloseYourIt::SlowMethodEvent do
  def configuration(**over)
    CloseYourIt::Configuration.new.tap do |c|
      c.environment = "test"
      over.each { |key, value| c.public_send("#{key}=", value) }
    end
  end

  def arguments(config, args: nil, kwargs: nil)
    described_class.new("job.run", 250.0, nil, config, args: args, kwargs: kwargs).to_h["arguments"]
  end

  it "omits the arguments by default (capture_method_arguments OFF)" do
    expect(arguments(configuration, args: [ "x" ], kwargs: { a: 1 })).to be_nil
  end

  # CYRB-28 — positional arguments were sent after `inspect` only: a bearer token or any value
  # matched by scrub_message_patterns went out in clear. They now go through the same message
  # scrubbing as exception messages (built-in auth schemes + user patterns).
  it "redacts credentials and scrub_message_patterns inside positional arguments" do
    config = configuration(capture_method_arguments: true, scrub_message_patterns: [ /\d{3}-\d{4}/ ])

    expect(arguments(config, args: [ "Authorization: Bearer hunter2", "call 555-1234", 42 ])).to eq(
      [
        { "name" => "arg1", "value" => "\"Authorization: Bearer [FILTERED]\"" },
        { "name" => "arg2", "value" => "\"call [FILTERED]\"" },
        { "name" => "arg3", "value" => "42" }
      ]
    )
  end

  it "redacts kwargs by sensitive key and by message pattern" do
    config = configuration(capture_method_arguments: true, scrub_message_patterns: [ /\d{3}-\d{4}/ ])

    expect(arguments(config, kwargs: { password: "x", ref: "555-1234", note: "ok" })).to eq(
      [
        { "name" => "password", "value" => "[FILTERED]" },
        { "name" => "ref", "value" => "\"[FILTERED]\"" },
        { "name" => "note", "value" => "\"ok\"" }
      ]
    )
  end
end
