# frozen_string_literal: true

# Smoke of the INSTALLED gem (outside bundler and the repo's `lib/`): require, no-op configuration
# and public API must work as in a real app. Run by `script/smoke_install.rb` in a clean process with
# an isolated GEM_HOME. Any failed assert → exit != 0 → red CI/release.

require "closeyourit-ruby"

def assert(condition, message)
  raise "SMOKE FAILED: #{message}" unless condition
end

# 1. The require loads the module and its version.
assert(defined?(CloseYourIt) == "constant", "CloseYourIt module not defined after require")
assert(CloseYourIt::VERSION.is_a?(String) && !CloseYourIt::VERSION.empty?, "VERSION not set")

# 2. Without Rails the railtie is NOT loaded: the integration is optional and must not break require.
assert(!defined?(CloseYourIt::Rails::Railtie), "Railtie loaded without Rails present")

# 3. Deterministic no-op configuration: without endpoint/token/project_id the client is disabled,
#    but init does not raise and stays configured. Credentials are forced to nil so the outcome does
#    not depend on the ENV of the environment the smoke runs in.
CloseYourIt.init do |c|
  c.endpoint_url = nil
  c.token = nil
  c.project_id = nil
end
assert(CloseYourIt.configured?, "configured? false after init")
assert(CloseYourIt.enabled? == false, "enabled? true without credentials (should be a no-op)")

# 4. Public API: when disabled it is a fire-and-forget no-op, does not raise and returns consistently.
assert(CloseYourIt.capture_exception(RuntimeError.new("boom")).nil?, "capture_exception is not a no-op")
assert(CloseYourIt.capture_message("hello").nil?, "capture_message is not a no-op")
assert(CloseYourIt.log(:info, "hello").nil?, "log is not a no-op")
assert(CloseYourIt.measure("smoke") { 21 * 2 } == 42, "measure does not return the block value")
assert(CloseYourIt.stats.to_h.is_a?(Hash), "stats.to_h is not a Hash")

# 5. Scope and breadcrumbs do not raise (surface used by middleware/extensions).
CloseYourIt.set_tag(:area, "smoke")
CloseYourIt.add_breadcrumb(message: "smoke")
CloseYourIt.configure_scope { |s| s.set_extra(:k, "v") }

# 6. Clean end-of-life shutdown.
CloseYourIt.shutdown

puts "SMOKE OK — Ruby #{RUBY_VERSION}, gem closeyourit-ruby #{CloseYourIt::VERSION}"
