# frozen_string_literal: true

require "digest"
require_relative "../support/open_dashboard_contract"

RSpec.describe "Open Dashboard contract v1" do
  it "matches the locked snapshot and all checksums" do
    lock = JSON.parse(File.read(File.join(OpenDashboardContract::ROOT, "LOCK.json")))
    sums = File.read(File.join(OpenDashboardContract::DIR, "SHA256SUMS"))
    expect(Digest::SHA256.hexdigest(sums)).to eq(lock.fetch("sha256sums"))

    sums.each_line do |line|
      expected, relative = line.strip.split("  ./", 2)
      expect(Digest::SHA256.file(File.join(OpenDashboardContract::DIR, relative)).hexdigest).to eq(expected), relative
    end
  end

  it "applies the declared validity to every fixture" do
    OpenDashboardContract.json("manifest.json").fetch("fixtures").each do |fixture|
      valid = OpenDashboardContract.validator.valid?(OpenDashboardContract.json(fixture.fetch("path")))
      expect(valid).to eq(fixture.fetch("valid")), fixture.fetch("path")
    end
  end
end
