# frozen_string_literal: true

# Builds the candidate gem, checks its metadata/contents, installs it into an isolated GEM_HOME
# and runs the smoke (`smoke_program.rb`) in a clean process. Reproduces the install a real app does
# on the current Ruby version of the CI matrix: if gemspec, minimum runtime or packaging are not
# really compatible, it exits != 0 and blocks CI/release (CYRB-13).
#
# Usage: `ruby script/smoke_install.rb` (NOT under bundler: it emulates a clean install).

require "tmpdir"
require "fileutils"
require "rbconfig"
require "rubygems/package"

ROOT = File.expand_path("..", __dir__)
GEMSPEC = File.join(ROOT, "closeyourit-ruby.gemspec")

# Subprocesses run WITHOUT bundler and without the repo's `lib/` in the load path: so `require`
# resolves the INSTALLED gem and not the local sources (which would mask incomplete packaging).
CLEAN_ENV = { "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil }.freeze

def run!(*cmd, env: {})
  puts "$ #{cmd.join(' ')}"
  raise "command failed (exit #{$?.exitstatus}): #{cmd.join(' ')}" unless system(env, *cmd)
end

# Checks the metadata and contents of the BUILT package (not just the source gemspec).
def verify_package!(gem_path)
  spec = Gem::Package.new(gem_path).spec
  files = spec.files

  %w[lib/closeyourit-ruby.rb lib/closeyourit/version.rb README.md LICENSE.txt].each do |f|
    raise "expected file missing from the package: #{f}" unless files.include?(f)
  end

  on_disk = Dir[File.join(ROOT, "lib/**/*.rb")].map { |p| p.sub("#{ROOT}/", "") }
  excluded = on_disk - files
  raise "lib files excluded from the package: #{excluded.join(', ')}" unless excluded.empty?

  %w[concurrent-ruby logger].each do |dep|
    next if spec.dependencies.any? { |d| d.name == dep && d.type == :runtime }

    raise "#{dep} not declared as a runtime dependency (needed to install on a clean GEM_HOME)"
  end

  unless spec.required_ruby_version.satisfied_by?(Gem::Version.new("4.0"))
    raise "required_ruby_version (#{spec.required_ruby_version}) does not allow the declared minimum 4.0"
  end

  puts "META OK — #{spec.full_name}, #{files.size} file, ruby #{spec.required_ruby_version}"
end

Dir.mktmpdir("cyi-smoke") do |dir|
  gem_home = File.join(dir, "gem_home")
  FileUtils.mkdir_p(gem_home)
  built = File.join(dir, "closeyourit-ruby.gem")

  # 1. Build the candidate gem (cwd = ROOT so `spec.files` resolves the relative Dir[...]).
  Dir.chdir(ROOT) { run!("gem", "build", GEMSPEC, "--output", built, env: CLEAN_ENV) }

  # 2. Metadata/contents of the built .gem.
  verify_package!(built)

  # 3. Install into an isolated GEM_HOME (installs the runtime dependencies too).
  install_env = CLEAN_ENV.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
  run!("gem", "install", built, "--no-document", env: install_env)

  # 4. Smoke require + API in a clean process, with cwd OUTSIDE the repo so `require` loads
  #    the installed gem and not `lib/`.
  smoke = File.join(ROOT, "script", "smoke_program.rb")
  Dir.chdir(dir) { run!(RbConfig.ruby, smoke, env: install_env) }
end
