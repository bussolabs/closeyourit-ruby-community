# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
  # ≥90% line AND branch gate enabled at the end of development (see PDR §12 final gate): line
  # coverage alone does not catch never-exercised defensive branches (no-op guards, error paths), so
  # branch coverage is enforced at 90 too (CYRB-13). Active with COVERAGE_ENFORCE.
  minimum_coverage line: 90, branch: 90 if ENV["COVERAGE_ENFORCE"]
end

require "closeyourit-ruby"
require "webmock/rspec"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Every test starts from a clean configuration, client, log buffer and scope. The log buffer must be
  # cleared explicitly: since CYRB-10 `init` DRAINS the previous buffer (flush), so a buffer left over
  # by a previous test would otherwise be flushed by the next test's first `init` → spurious unstubbed
  # HTTP request. Before dropping it, though, its TimerTask must be stopped: just clearing it would
  # make it unreachable while it keeps running (and flushing over HTTP) between tests, and would take
  # away from the next `init` the chance to stop it. `timer.shutdown` stops the task WITHOUT flushing.
  config.before do
    previous_buffer = CloseYourIt.instance_variable_get(:@log_buffer)
    previous_buffer&.timer&.shutdown
    CloseYourIt.instance_variable_set(:@configuration, nil)
    CloseYourIt.instance_variable_set(:@client, nil)
    CloseYourIt.instance_variable_set(:@log_buffer, nil)
    # PID where the client/buffer were materialized (fork detection, CYRB-11): cleared so a test that
    # stubs `Process.pid` to simulate a child does not leave a stale value for the next test.
    CloseYourIt.instance_variable_set(:@pid, nil)
    CloseYourIt.stats.reset!
    CloseYourIt::Scope.reset!
    CloseYourIt::OpenDashboard.reset!
  end
end
