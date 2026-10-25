# frozen_string_literal: true

RSpec.describe CloseYourIt::Subscribers::SlowQuery do
  let(:url) { "https://closeyour.it/api/v1/projects/proj-1/metrics" }

  def enable!(threshold: 100)
    CloseYourIt.init do |c|
      c.endpoint_url = "https://closeyour.it"
      c.token = "tok"
      c.project_id = "proj-1"
      c.async_threads = 0
      c.slow_query_threshold_ms = threshold
    end
  end

  def record(**over)
    defaults = { name: "User Load", duration_ms: 150, sql: "SELECT 1", cached: false }
    described_class.new.record(**defaults.merge(over))
  end

  it "does not send below the threshold (X-1)" do
    enable!(threshold: 100)
    stub = stub_request(:post, url)
    record(duration_ms: 99)
    expect(stub).not_to have_been_requested
  end

  it "sends at the exact threshold (X)" do
    enable!(threshold: 100)
    stub = stub_request(:post, url)
    record(duration_ms: 100)
    expect(stub).to have_been_requested.times(1)
  end

  it "sends above the threshold (X+1) on the /metrics path" do
    enable!(threshold: 100)
    stub = stub_request(:post, url)
    record(duration_ms: 101)
    expect(stub).to have_been_requested.times(1)
  end

  it "ignores SCHEMA and CACHE even when very slow" do
    enable!(threshold: 1)
    stub = stub_request(:post, url)
    record(name: "SCHEMA", duration_ms: 999)
    record(name: "CACHE", duration_ms: 999)
    expect(stub).not_to have_been_requested
  end

  it "builds slow_query with sample_id, obfuscated SQL, db_system and no binds" do
    enable!(threshold: 1)
    stub_request(:post, url)
    connection = double("connection", adapter_name: "PostgreSQL")

    record(
      name: "User Load",
      duration_ms: 50,
      sql: "SELECT * FROM users WHERE email = 'a@b.com'",
      cached: true,
      connection: connection
    )

    expect(WebMock).to have_requested(:post, url).with { |req|
      body = JSON.parse(req.body)
      body["kind"] == "slow_query" &&
        body["sample_id"].is_a?(String) &&
        body["name"] == "User Load" &&
        body["cached"] == true &&
        body["db_system"] == "postgresql" &&
        !body["sql"].include?("a@b.com") &&
        !body.key?("binds")
    }
  end

  it "always includes the source (call site), even with bind capture OFF" do
    enable!(threshold: 1)
    stub_request(:post, url)

    record(duration_ms: 50, source: "app/models/order.rb:42")

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body)["source"] == "app/models/order.rb:42"
    }
  end

  it "does NOT include bindings when capture_query_bindings is OFF (privacy default)" do
    enable!(threshold: 1)
    stub_request(:post, url)
    attr = double("attr", name: "email")

    record(duration_ms: 50, binds: [ attr ], type_casted_binds: [ "a@b.com" ])

    expect(WebMock).to have_requested(:post, url).with { |req|
      !JSON.parse(req.body).key?("bindings")
    }
  end

  it "includes bindings (scrubbed by column) when capture_query_bindings is ON" do
    enable!(threshold: 1)
    CloseYourIt.configuration.capture_query_bindings = true
    stub_request(:post, url)
    order = double("attr", name: "order_id")
    pw = double("attr", name: "password")

    record(duration_ms: 50, binds: [ order, pw ], type_casted_binds: [ 42, "secret" ])

    expect(WebMock).to have_requested(:post, url).with { |req|
      JSON.parse(req.body)["bindings"] == [
        { "name" => "order_id", "value" => "42" },
        { "name" => "password", "value" => "[FILTERED]" }
      ]
    }
  end

  # The call site costs a full backtrace plus the Rails cleaner: it is resolved only for a query
  # that is actually sent or profiled, never for the fast ones.
  describe "lazy call site" do
    let(:calls) { [] }
    let(:source) { -> { calls << :resolved; "app/models/order.rb:42" } }

    it "does not resolve the call site of a query under the threshold" do
      enable!(threshold: 100)
      record(duration_ms: 10, source: source)

      expect(calls).to be_empty
    end

    it "resolves the call site of a slow query and sends its value" do
      enable!(threshold: 100)
      stub = stub_request(:post, url).with { |req| req.body.include?("app/models/order.rb:42") }
      record(duration_ms: 150, source: source)

      expect(calls).to eq([ :resolved ])
      expect(stub).to have_been_requested.times(1)
    end

    it "notify resolves the call site once for both the slow query and the profile" do
      enable!(threshold: 100)
      CloseYourIt.configuration.detect_performance_issues = true
      stub_request(:post, url)
      payload = { name: "User Load", sql: "SELECT 1", cached: false }

      described_class.new.notify(payload, 150, source)

      expect(calls).to eq([ :resolved ])
    end

    it "notify never resolves the call site of a fast query with detection off" do
      enable!(threshold: 100)
      described_class.new.notify({ name: "User Load", sql: "SELECT 1" }, 10, source)

      expect(calls).to be_empty
    end

    it "does not resolve the call site for the profile when detection is off" do
      enable!(threshold: 1)
      described_class.new.profile(name: "User Load", sql: "SELECT 1", duration_ms: 50, source: source)

      expect(calls).to be_empty
    end
  end

  # CYRB-2 — the subscriber runs on the host query's thread (the Railtie's sql.active_record block).
  # If before_send or the scrubber raise, the exception would bubble up into the subscriber and
  # ActiveSupport would re-raise it as an instrumentation error, disturbing the app's query. Telemetry
  # must NEVER crash the host: each of the three public methods (record/breadcrumb/profile) absorbs it.
  describe "resilience: telemetry does not disturb the host query (CYRB-2)" do
    it "record does not raise when before_send raises on the payload" do
      enable!(threshold: 1)
      CloseYourIt.configuration.before_send = ->(_payload) { raise "boom in before_send" }
      stub_request(:post, url)

      expect { record(duration_ms: 50) }.not_to raise_error
    end

    it "record does not raise when a malformed bind makes payload building raise (capture_query_bindings ON)" do
      enable!(threshold: 1)
      CloseYourIt.configuration.capture_query_bindings = true
      stub_request(:post, url)
      attr = double("attr", name: "order_id")
      faulty = Object.new
      def faulty.to_s = raise("malformed bind")

      expect {
        record(duration_ms: 50, binds: [ attr ], type_casted_binds: [ faulty ])
      }.not_to raise_error
    end

    it "breadcrumb does not raise when the scrubber raises obfuscating the SQL" do
      enable!(threshold: 1) # breadcrumbs_enabled is true by default
      allow_any_instance_of(CloseYourIt::Scrubber).to receive(:obfuscate_sql).and_raise("scrubber boom")

      expect {
        described_class.new.breadcrumb(name: "User Load", sql: "SELECT 1", duration_ms: 50)
      }.not_to raise_error
    end

    it "profile does not raise when the scrubber raises (invariant already guaranteed, guarded against regressions)" do
      enable!(threshold: 1)
      CloseYourIt.configuration.detect_performance_issues = true
      allow_any_instance_of(CloseYourIt::Scrubber).to receive(:obfuscate_sql).and_raise("scrubber boom")

      expect {
        described_class.new.profile(name: "User Load", sql: "SELECT 1", duration_ms: 50)
      }.not_to raise_error
    end
  end

  # CYRB-18: the Solid stack service tables are framework infrastructure. A slow query on them cannot
  # be fixed by reading your own repo, and it floods the app's ones: on closeyourit-rails on 2026-07-30
  # they were about 2,740 samples out of 4,400 (62%), all between 250 and 655 ms.
  describe "exclusion of service queries (excluded_query_patterns)" do
    # Real SQL observed in production, the two largest groups.
    let(:solid_queue_insert) do
      'INSERT INTO "solid_queue_jobs" ("active_job_id", "class_name", "queue_name") ' \
        "VALUES ($1, $2, $3) RETURNING \"id\""
    end

    it "does not measure an INSERT on solid_queue_jobs, however slow" do
      enable!(threshold: 1)
      stub = stub_request(:post, url)

      record(name: "SolidQueue::Job Create", duration_ms: 655, sql: solid_queue_insert)
      expect(stub).not_to have_been_requested
    end

    it "does not measure reads of solid_queue_jobs" do
      enable!(threshold: 1)
      stub = stub_request(:post, url)

      record(name: "SolidQueue::Job Load", duration_ms: 527,
             sql: 'SELECT "solid_queue_jobs".* FROM "solid_queue_jobs" WHERE "id" = $1 LIMIT $2')
      expect(stub).not_to have_been_requested
    end

    it "also excludes the Solid stack cache and cable" do
      enable!(threshold: 1)
      stub = stub_request(:post, url)

      record(duration_ms: 300, sql: 'SELECT "solid_cache_entries".* FROM "solid_cache_entries"')
      record(duration_ms: 300, sql: 'INSERT INTO "solid_cable_messages" ("channel") VALUES ($1)')
      expect(stub).not_to have_been_requested
    end

    it "keeps measuring the application queries" do
      enable!(threshold: 1)
      stub = stub_request(:post, url)

      record(duration_ms: 300, sql: 'SELECT "ticketing_tickets".* FROM "ticketing_tickets"')
      expect(stub).to have_been_requested.times(1)
    end

    it "does not exclude an app table containing the word queue" do
      enable!(threshold: 1)
      stub = stub_request(:post, url)

      # `\b` before solid_queue_: an app's own table must not disappear because of a similar name.
      record(duration_ms: 300, sql: 'SELECT "agents_ticket_queues".* FROM "agents_ticket_queues"')
      expect(stub).to have_been_requested.times(1)
    end

    it "measures everything again with the list cleared" do
      enable!(threshold: 1)
      CloseYourIt.configuration.excluded_query_patterns = []
      stub = stub_request(:post, url)

      record(duration_ms: 655, sql: solid_queue_insert)
      expect(stub).to have_been_requested.times(1)
    end

    it "accepts a String and treats it as literal text" do
      enable!(threshold: 1)
      CloseYourIt.configuration.excluded_query_patterns = [ "pg_stat_activity" ]
      stub = stub_request(:post, url)

      record(duration_ms: 300, sql: "SELECT count(*) FROM pg_stat_activity")
      expect(stub).not_to have_been_requested
    end

    it "handles a missing SQL without raising" do
      enable!(threshold: 1)
      stub_request(:post, url)

      expect { record(duration_ms: 300, sql: nil) }.not_to raise_error
    end

    # The filter answers "is it worth measuring", not "is it worth knowing": the history of queries
    # before a crash stays complete on the service tables too.
    it "keeps the breadcrumb even for a query excluded from measurement" do
      enable!(threshold: 1)
      allow(CloseYourIt).to receive(:add_breadcrumb)

      described_class.new.breadcrumb(name: "SolidQueue::Job Create", sql: solid_queue_insert,
                                     duration_ms: 655)
      expect(CloseYourIt).to have_received(:add_breadcrumb)
    end
  end
end
