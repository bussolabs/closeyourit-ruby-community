# frozen_string_literal: true

RSpec.describe CloseYourIt::Scope do
  subject(:scope) { described_class.new }

  describe "mutators and #to_event_hash" do
    it "is empty when the scope is clean" do
      expect(scope.to_event_hash).to eq({})
    end

    it "collects tags, extra and context in Sentry shape" do
      scope.set_tag(:area, "checkout")
      scope.set_extra(:order_id, 42)
      scope.set_context(:active_job, { job_id: "abc", executions: 1 })

      hash = scope.to_event_hash
      expect(hash["tags"]).to eq("area" => "checkout")
      expect(hash["extra"]).to eq("order_id" => 42)
      expect(hash["contexts"]).to eq("active_job" => { "job_id" => "abc", "executions" => 1 })
    end

    it "set_tags merges several tags at once" do
      scope.set_tags(a: "1", b: "2")
      scope.set_tags(b: "3")
      expect(scope.to_event_hash["tags"]).to eq("a" => "1", "b" => "3")
    end

    it "exposes request when set by the middleware" do
      scope.request = { "method" => "GET", "url" => "https://x/y" }
      expect(scope.to_event_hash["request"]).to eq("method" => "GET", "url" => "https://x/y")
    end

    # CYRB-28 — the send_pii guard runs first, so the rack_env nil guard is reachable only with
    # send_pii ON (a request set by hand, outside the middleware).
    it "exposes request without data when send_pii is on but there is no rack env" do
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.send_pii = true
      end
      scope.request = { "method" => "POST", "url" => "https://x/y" }
      expect(scope.to_event_hash["request"]).to eq("method" => "POST", "url" => "https://x/y")
    end
  end

  # R2 — the backend does NOT scrub tags/extra/contexts again (Errors::Ingest::Normalize keeps them
  # verbatim): without client-side scrubbing a sensitive key there would leak with no server-side net.
  describe "scrubbing of tags/extra/contexts (R2)" do
    it "redacts sensitive keys in tags/extra/contexts, keeping the others" do
      scope.set_tag("password", "x")
      scope.set_tag("plan", "pro")
      scope.set_extra("api_key", "secret")
      scope.set_extra("order_id", 42)
      scope.set_context("auth", { token: "abc", scheme: "bearer" })

      hash = scope.to_event_hash
      expect(hash["tags"]).to eq("password" => "[FILTERED]", "plan" => "pro")
      expect(hash["extra"]).to eq("api_key" => "[FILTERED]", "order_id" => 42)
      expect(hash["contexts"]).to eq("auth" => { "token" => "[FILTERED]", "scheme" => "bearer" })
    end

    it "keeps the structure of a context (non-sensitive key), scrubbing only values under sensitive keys" do
      scope.set_context("runtime", { name: "ruby", version: "4.0" })
      scope.set_context("prefs", { passphrase: "p", note: "ok" })

      contexts = scope.to_event_hash["contexts"]
      expect(contexts["runtime"]).to eq("name" => "ruby", "version" => "4.0")
      expect(contexts["prefs"]).to eq("passphrase" => "[FILTERED]", "note" => "ok")
    end

    it "redacts the whole subtree when the context key itself is sensitive" do
      scope.set_context("credit_card", { number: "x", expiry: "y" })

      expect(scope.to_event_hash["contexts"]).to eq("credit_card" => "[FILTERED]")
    end
  end

  describe "#serialize_user — PII gated" do
    it "keeps only id when send_pii is false (default)" do
      scope.set_user(id: 7, email: "a@b.com", ip_address: "1.2.3.4")
      expect(scope.to_event_hash["user"]).to eq("id" => 7)
    end

    it "keeps email/ip when send_pii is true" do
      CloseYourIt.init do |c|
        c.endpoint_url = "https://closeyour.it"
        c.token = "tok"
        c.project_id = "proj-1"
        c.send_pii = true
      end
      scope.set_user(id: 7, email: "a@b.com")
      expect(scope.to_event_hash["user"]).to eq("id" => 7, "email" => "a@b.com")
    end
  end

  describe "execution-local storage" do
    it "current returns the same instance in the same context" do
      expect(described_class.current).to be(described_class.current)
    end

    it "reset! clears the current scope" do
      described_class.current.set_tag(:x, "1")
      described_class.reset!
      expect(described_class.current.to_event_hash).to eq({})
    end

    it "isolates the scope between threads" do
      described_class.current.set_user(id: "main")
      other = Thread.new { described_class.current.user.dup }.value

      expect(other).to eq({})
      expect(described_class.current.user).to eq("id" => "main")
    end
  end

  describe "module-level API (delegating to the current scope)" do
    after { CloseYourIt.clear_scope }

    it "CloseYourIt.set_user/set_tag/set_context populate the current scope" do
      CloseYourIt.set_user(id: 1)
      CloseYourIt.set_tag(:env, "prod")
      CloseYourIt.set_context(:device, { os: "linux" })

      hash = CloseYourIt::Scope.current.to_event_hash
      expect(hash["user"]).to eq("id" => 1)
      expect(hash["tags"]).to eq("env" => "prod")
      expect(hash["contexts"]).to eq("device" => { "os" => "linux" })
    end

    it "configure_scope yields the current scope" do
      CloseYourIt.configure_scope do |s|
        s.set_tag(:via, "block")
      end
      expect(CloseYourIt::Scope.current.to_event_hash["tags"]).to eq("via" => "block")
    end

    it "clear_scope clears it" do
      CloseYourIt.set_tag(:x, "1")
      CloseYourIt.clear_scope
      expect(CloseYourIt::Scope.current.to_event_hash).to eq({})
    end
  end

  describe "merge into the ErrorEvent" do
    let(:config) do
      CloseYourIt::Configuration.new.tap do |c|
        c.environment = "test"
        c.project_id = "proj-1"
      end
    end

    def boom
      raise "boom"
    rescue RuntimeError => e
      e
    end

    it "merges the scope user/tags/extra/contexts into the payload, keeping contexts.runtime" do
      CloseYourIt.set_user(id: 9)
      CloseYourIt.set_tag(:area, "checkout")
      CloseYourIt.set_context(:active_job, { job_id: "j1" })

      payload = CloseYourIt::ErrorEvent.from_exception(boom, configuration: config).to_h

      expect(payload["user"]).to eq("id" => 9)
      expect(payload["tags"]).to eq("area" => "checkout")
      expect(payload.dig("contexts", "runtime", "name")).to eq("ruby")
      expect(payload.dig("contexts", "active_job")).to eq("job_id" => "j1")
    ensure
      CloseYourIt.clear_scope
    end
  end
end
