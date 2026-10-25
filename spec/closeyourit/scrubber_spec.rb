# frozen_string_literal: true

RSpec.describe CloseYourIt::Scrubber do
  def scrubber(**over)
    config = CloseYourIt::Configuration.new
    over.each { |k, v| config.public_send("#{k}=", v) }
    described_class.new(config)
  end

  describe "PostgreSQL dollar quoted SQL" do
    it "redacts tagged and untagged values while preserving parameter positions" do
      sql = 'SELECT $$PrivateMarker$$, $audit$OtherMarker$audit$, $1'
      expect(scrubber.obfuscate_sql(sql)).to eq('SELECT ?, ?, $1')
    end

    it "redacts multiline and unterminated dollar quoted values" do
      expect(scrubber.obfuscate_sql("SELECT $$private\nvalue$$")).to eq('SELECT ?')
      expect(scrubber.obfuscate_sql('SELECT $tag$PrivateMarker')).to eq('SELECT ?')
    end

    it "respects the explicit obfuscation opt-out" do
      sql = 'SELECT $$visible$$'
      expect(scrubber(obfuscate_sql: false).obfuscate_sql(sql)).to eq(sql)
    end
  end

  describe "#filter_params" do
    it "redacts sensitive keys (denylist) even when nested" do
      out = scrubber.filter_params(
        "name" => "Mario",
        "password" => "p",
        "nested" => { "api_key" => "x", "ok" => 1 }
      )
      expect(out).to eq(
        "name" => "Mario",
        "password" => "[FILTERED]",
        "nested" => { "api_key" => "[FILTERED]", "ok" => 1 }
      )
    end

    it "redacts Authorization and Cookie" do
      out = scrubber.filter_params("Authorization" => "Bearer x", "Cookie" => "a=b")
      expect(out.values).to all(eq("[FILTERED]"))
    end

    # NB: we use `badge` as the custom parameter example because it is NOT in the DENYLIST
    # (unlike `pin`, now built in via CYRB-3): so the test really exercises
    # `filter_parameters`, not the denylist.
    it "honors custom filter_parameters (string and regexp)" do
      out = scrubber(filter_parameters: [ "badge", /\Ahidden/ ]).filter_params(
        "user_badge" => "1234", "hidden_x" => "y", "other" => "z"
      )
      expect(out).to eq("user_badge" => "[FILTERED]", "hidden_x" => "[FILTERED]", "other" => "z")
    end

    it "filters inside arrays" do
      out = scrubber.filter_params([ { "token" => "t" }, { "ok" => 1 } ])
      expect(out).to eq([ { "token" => "[FILTERED]" }, { "ok" => 1 } ])
    end
  end

  # R1 — the denylist must cover the same tokens as the backend and Dart client regex:
  #   /pass|secret|token|api[_-]?key|apikey|authorization|cookie|csrf|credit|card|cvv|ssn|iban/i
  # In particular the `pass*` ones (pass, pass_code, passkey, passphrase) the literal list omitted.
  describe "denylist parity (R1) — backend/Dart regex tokens" do
    sensitive = %w[
      pass pass_code passkey passphrase password passwd
      secret token api_key apiKey x-api-key
      authorization cookie set-cookie csrf
      credit credit_card card cvv ssn iban
    ]

    sensitive.each do |key|
      it "redacts the sensitive key #{key.inspect}" do
        expect(scrubber.filter_params(key => "v")).to eq(key => "[FILTERED]")
      end
    end

    %w[message user_id name].each do |key|
      it "does NOT redact the benign key #{key.inspect}" do
        expect(scrubber.filter_params(key => "v")).to eq(key => "v")
      end
    end

    it "redacts `pass*` keys even nested and inside arrays" do
      out = scrubber.filter_params(
        "passphrase" => "p",
        "nested" => { "passkey" => "k", "ok" => 1 },
        "list" => [ { "pass" => "x" } ]
      )
      expect(out).to eq(
        "passphrase" => "[FILTERED]",
        "nested" => { "passkey" => "[FILTERED]", "ok" => 1 },
        "list" => [ { "pass" => "[FILTERED]" } ]
      )
    end
  end

  # CYRB-3 — the SDK DENYLIST was narrower than the backend PII denylist (SENSITIVE_KEY):
  # slow query/method binds on email/phone/dob (and similar) columns were NOT redacted and ended up
  # in the "Parameters" panel of the metric-group show page, visible to every viewer.
  # Alignment: added email phone telephone mobile dob birth passport bearer session pin pan.
  describe "denylist PII backend parity (CYRB-3)" do
    pii = %w[
      email phone telephone mobile
      dob birth passport bearer session pin pan
    ]

    pii.each do |key|
      it "redacts the PII key #{key.inspect}" do
        expect(scrubber.filter_params(key => "v")).to eq(key => "[FILTERED]")
      end
    end

    # Realistic column/parameter names: they fall by substring match (like the backend regex).
    {
      "user_email"      => "email",
      "email_address"   => "email",
      "phone_number"    => "phone",
      "telephone"       => "telephone",
      "mobile_number"   => "mobile",
      "date_of_birth"   => "birth",
      "passport_number" => "passport",
      "bearer_token"    => "bearer",
      "session_id"      => "session",
      "pin_code"        => "pin",
      "card_pan"        => "pan"
    }.each do |column, token|
      it "redacts the column #{column.inspect} (token #{token.inspect})" do
        expect(scrubber.filter_value(column, "x")).to eq("[FILTERED]")
      end
    end

    %w[message user_id name order_id created_at].each do |key|
      it "does NOT redact the benign key #{key.inspect}" do
        expect(scrubber.filter_params(key => "v")).to eq(key => "v")
      end
    end
  end

  # CYRB-3 Scenario 1 — slow query bind on a PII column with capture_query_bindings on:
  # filter_value must redact the value so it never reaches the backend/panel.
  describe "#filter_value — slow query PII bind (CYRB-3 Scenario 1)" do
    it "redacts the email/phone/dob bind value" do
      expect(scrubber.filter_value("email", "a@b.com")).to eq("[FILTERED]")
      expect(scrubber.filter_value("phone", "+390123456789")).to eq("[FILTERED]")
      expect(scrubber.filter_value("dob", "1990-01-01")).to eq("[FILTERED]")
    end

    it "keeps the value of a non-PII column" do
      expect(scrubber.filter_value("total_amount", 1299)).to eq(1299)
    end
  end

  describe "#obfuscate_sql" do
    it "masks string and numeric literals when enabled" do
      sql = "SELECT * FROM users WHERE email = 'a@b.com' AND age = 42"
      out = scrubber(obfuscate_sql: true).obfuscate_sql(sql)
      expect(out).not_to include("a@b.com")
      expect(out).not_to include("42")
      expect(out).to include("SELECT", "FROM users", "WHERE email =")
    end

    it "passes through when disabled" do
      expect(scrubber(obfuscate_sql: false).obfuscate_sql("SELECT 1")).to eq("SELECT 1")
    end
  end

  describe "#scrub_message" do
    it "applies scrub_message_patterns" do
      out = scrubber(scrub_message_patterns: [ /secret-\d+/ ]).scrub_message("leaked secret-123 here")
      expect(out).to eq("leaked [FILTERED] here")
    end

    it "returns the message unchanged without patterns" do
      expect(scrubber.scrub_message("hello")).to eq("hello")
    end

    # CYRB-23: BUILT-IN redaction rule for authentication schemes. Before this ticket
    # `scrub_message` applied only the user-configured patterns (default `[]`) → an
    # `Authorization: Bearer <token>` ending up in an exception message was sent in clear.
    # Chosen shape (once for all SDKs): key and scheme stay readable, ONLY the credential
    # disappears → `Authorization: Bearer [FILTERED]`.
    # The tokens below are placeholders: no real credentials in tests.
    describe "built-in redaction of authentication schemes (CYRB-23)" do
      it "redacts the value of an Authorization header inside a free message" do
        out = scrubber.scrub_message("401 on GET /me (Authorization: Bearer cyi_placeholder_0123456789)")
        expect(out).to eq("401 on GET /me (Authorization: Bearer [FILTERED])")
      end

      it "redacts the bare scheme, without the header name" do
        out = scrubber.scrub_message("retry with Bearer cyi_placeholder_0123456789 failed")
        expect(out).to eq("retry with Bearer [FILTERED] failed")
      end

      it "redacts a JWT (dots and dashes in the token68)" do
        out = scrubber.scrub_message("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJwbGFjZWhvbGRlciJ9.sig-0123")
        expect(out).to eq("Bearer [FILTERED]")
      end

      it "redacts Basic (padded base64) and Token" do
        expect(scrubber.scrub_message("Basic cGxhY2Vob2xkZXI6cGxhY2Vob2xkZXI=")).to eq("Basic [FILTERED]")
        expect(scrubber.scrub_message("Token cyi_placeholder_0123")).to eq("Token [FILTERED]")
      end

      it "ignores the case of header and scheme" do
        out = scrubber.scrub_message("AUTHORIZATION: BEARER CYI_PLACEHOLDER_0123456789")
        expect(out).to eq("AUTHORIZATION: BEARER [FILTERED]")
      end

      it "redacts Proxy-Authorization and the `key=value` form" do
        expect(scrubber.scrub_message("Proxy-Authorization: Basic cGxhY2Vob2xkZXI=")).to eq("Proxy-Authorization: Basic [FILTERED]")
        expect(scrubber.scrub_message("authorization=cyi_placeholder_0123")).to eq("authorization=[FILTERED]")
      end

      it "redacts every line of a multiline message without crossing the newline" do
        out = scrubber.scrub_message(
          "POST /events\nAuthorization: Bearer cyi_placeholder_0123456789\nContent-Type: application/json\nBearer cyi_placeholder_9876543210\nend"
        )
        expect(out).to eq(
          "POST /events\nAuthorization: Bearer [FILTERED]\nContent-Type: application/json\nBearer [FILTERED]\nend"
        )
      end

      it "does NOT touch prose containing the word bearer/basic/token" do
        [
          "the bearer of bad news arrived",
          "invalid bearer credentials provided",
          "Basic authentication failed for user",
          "Token expired, please reauthenticate"
        ].each do |prose|
          expect(scrubber.scrub_message(prose)).to eq(prose)
        end
      end

      it "is idempotent: running it again does not erode already redacted text" do
        once = scrubber.scrub_message("Authorization: Bearer cyi_placeholder_0123456789")
        expect(scrubber.scrub_message(once)).to eq(once)
      end

      # Findings of the independent review on the first round (CYRB-23).
      it "redacts the quoted credential (`Token token=\"…\"`)" do
        out = scrubber.scrub_message('Authorization: Token token="cyi_placeholder_0123456789"')
        expect(out).to eq("Authorization: Token [FILTERED]")
        expect(out).not_to include("cyi_placeholder_0123456789")
      end

      it "redacts the value inside a JSON fragment pasted into the message too" do
        out = scrubber.scrub_message('request rejected: {"authorization": "Bearer cyi_placeholder_0123"}')
        expect(out).to eq('request rejected: {"authorization": [FILTERED]}')
      end

      it "redacts a long lowercase-only token (not prose: no word is that long)" do
        out = scrubber.scrub_message("Bearer abcdefabcdefabcdefabcdefabcdefab")
        expect(out).to eq("Bearer [FILTERED]")
      end

      it "redacts a short base64 with inner capitals (Basic with short credentials)" do
        expect(scrubber.scrub_message("Basic dTpw")).to eq("Basic [FILTERED]")
      end

      it "does NOT touch acronyms and capitalized words following the scheme" do
        [
          "Basic HTTP authentication is disabled",
          "Bearer Token expired",
          "Basic Authentication required"
        ].each { |prose| expect(scrubber.scrub_message(prose)).to eq(prose) }
      end

      it "adds up with the user's scrub_message_patterns (Scenario 2)" do
        out = scrubber(scrub_message_patterns: [ /secret-\d+/ ])
              .scrub_message("Authorization: Bearer cyi_placeholder_0123456789 and secret-123")
        expect(out).to eq("Authorization: Bearer [FILTERED] and [FILTERED]")
      end
    end
  end

  describe "#filter_value (single bind by column name)" do
    it "redacts the value of a sensitive column" do
      expect(scrubber.filter_value("password", "secret")).to eq("[FILTERED]")
      expect(scrubber.filter_value("api_token", "abc")).to eq("[FILTERED]")
    end

    it "keeps the value of a non-sensitive column" do
      expect(scrubber.filter_value("order_id", 42)).to eq(42)
    end

    # `badge` (not in the DENYLIST) really exercises the custom filter_parameters — see note above.
    it "honors custom filter_parameters" do
      expect(scrubber(filter_parameters: [ "badge" ]).filter_value("user_badge", "1234")).to eq("[FILTERED]")
    end
  end
end
