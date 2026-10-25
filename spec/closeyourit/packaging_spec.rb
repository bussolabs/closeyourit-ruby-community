# frozen_string_literal: true

require "spec_helper"

# Checks the gem packaging: declared metadata and consistency between `spec.files` and the filesystem.
# It is the fast gate (no build) next to the smoke install (`script/smoke_install.rb`): it catches a
# forgotten lib file or broken metadata right away, before it breaks the real install in CI (CYRB-13).
RSpec.describe "gem packaging" do
  let(:root) { File.expand_path("../..", __dir__) }

  # The gemspec computes `spec.files` with globs relative to the cwd: we load it FROM the root
  # (Dir.chdir) so the tests stay reliable even when RSpec runs from another directory (CYRB-13, review).
  let(:gemspec) do
    Dir.chdir(root) { Gem::Specification.load(File.join(root, "closeyourit-ruby.gemspec")) }
  end

  it "declares name and version aligned with the module" do
    expect(gemspec.name).to eq("closeyourit-ruby")
    expect(gemspec.version.to_s).to eq(CloseYourIt::VERSION)
  end

  it "allows the declared minimum Ruby version and rejects earlier ones" do
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.0"))).to be(true)
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0.5"))).to be(true)
    expect(gemspec.required_ruby_version.satisfied_by?(Gem::Version.new("3.9.0"))).to be(false)
  end

  it "exposes license and navigation metadata" do
    expect(gemspec.license).to eq("MIT")
    expect(gemspec.metadata["homepage_uri"]).to eq(gemspec.homepage)
    expect(gemspec.metadata["source_code_uri"]).to eq(gemspec.homepage)
  end

  it "declares the runtime dependencies needed for a clean install" do
    # `logger` is no longer a default gem since Ruby 4.0: without declaring it, requiring the entry
    # point blows up in an app that installs only this gem (CYRB-13).
    runtime = gemspec.dependencies.select { |d| d.type == :runtime }
    by_name = runtime.to_h { |d| [ d.name, d.requirement.to_s ] }
    expect(by_name).to eq("concurrent-ruby" => "~> 1.3", "logger" => "~> 1.6")
  end

  it "packages the entry point, the docs and the license" do
    expect(gemspec.files).to include(
      "lib/closeyourit-ruby.rb", "lib/closeyourit/version.rb", "README.md", "LICENSE.txt"
    )
    expect(gemspec.require_paths).to eq([ "lib" ])
  end

  it "includes EVERY source under lib/ so no file is left out of the package" do
    on_disk = Dir[File.join(root, "lib/**/*.rb")].map { |p| p.sub("#{root}/", "") }
    expect(gemspec.files).to include(*on_disk)
  end

  it "does not package the test files" do
    expect(gemspec.files.grep(%r{\Aspec/})).to be_empty
  end
end
