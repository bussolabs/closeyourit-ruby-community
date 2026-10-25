# frozen_string_literal: true

require "spec_helper"
require "yaml"

# Hardening of the public CI workflows (CYRB-16, CYRA-914 B8). Third-party actions must be pinned to
# a verifiable commit SHA (a tag like `@v1` can be repointed by its owner at will), the CI must run on
# GitHub-hosted runners with a read-only token, and Dependabot must watch both the gems and the
# actions. The maintainer repository checks its own private workflows with a sibling of this spec.
RSpec.describe "CI workflow hardening" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:workflow_dir) { File.join(root, ".github", "workflows") }
  let(:workflow_files) { Dir[File.join(workflow_dir, "*.yml")].sort }

  # `uses: owner/repo@ref` lines of external actions (excludes local `./…` uses).
  def external_uses(content)
    content.lines.map(&:chomp).grep(/^\s*(?:-\s*)?uses:/).reject { |l| l =~ %r{uses:\s*\./} }
  end

  it "finds the expected workflows" do
    expect(workflow_files.map { |f| File.basename(f) }).to include("ci.yml", "cla.yml")
  end

  describe "actions pinned to a verifiable SHA" do
    it "pins EVERY external action to a 40-digit commit SHA with the version comment" do
      offenders = []
      workflow_files.each do |file|
        external_uses(File.read(file)).each do |line|
          ok = line =~ %r{uses:\s*[\w.\-]+/[\w.\-]+(?:/[\w.\-/]+)?@\h{40}\s+#\s*v\d+(?:\.\d+)*}
          offenders << "#{File.basename(file)}: #{line.strip}" unless ok
        end
      end
      expect(offenders).to be_empty,
        "actions not pinned to a SHA (or missing the version comment):\n#{offenders.join("\n")}"
    end

    it "leaves no reference to a mutable tag (@vN, @main, @master, @latest)" do
      mutable = []
      workflow_files.each do |file|
        external_uses(File.read(file)).each do |line|
          mutable << "#{File.basename(file)}: #{line.strip}" if line =~ %r{@(?:v?\d+(?:\.\d+)*|main|master|latest)\s*$}
        end
      end
      expect(mutable).to be_empty, "remaining mutable references:\n#{mutable.join("\n")}"
    end
  end

  describe "the public CI" do
    let(:ci) { YAML.safe_load(File.read(File.join(workflow_dir, "ci.yml")), aliases: false) }

    it "declares top-level `permissions: contents: read`" do
      expect(ci["permissions"]).to eq("contents" => "read")
    end

    it "runs every job on GitHub-hosted runners" do
      expect(ci["jobs"].values.map { |job| job["runs-on"] }.uniq).to eq([ "ubuntu-latest" ])
    end
  end

  describe "Dependabot" do
    let(:path) { File.join(root, ".github", "dependabot.yml") }
    let(:config) { YAML.safe_load(File.read(path), aliases: false) }

    it "exists and uses format v2" do
      expect(File).to exist(path)
      expect(config["version"]).to eq(2)
    end

    it "watches both the gems (bundler) and the CI actions (github-actions)" do
      ecosystems = config["updates"].map { |u| u["package-ecosystem"] }
      expect(ecosystems).to include("bundler", "github-actions")
    end
  end
end
