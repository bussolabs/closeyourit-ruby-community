# frozen_string_literal: true

module CloseYourIt
  # PII removal from payloads: sensitive key filter, SQL normalization, message scrubbing.
  # Privacy-by-default — see PDR §9.
  class Scrubber
    FILTERED = "[FILTERED]"

    # Key tokens that are always redacted (substring match, normalized). Aligned with the
    # SENSITIVE_KEY regex of the backend and the Dart client (client-side parity) — see
    # Errors/Logs::Ingest::Normalize::SENSITIVE_KEY. Covers credentials/secrets and PII:
    #   /pass|secret|token|api[_-]?key|apikey|authorization|cookie|csrf|credit|card|cvv|ssn|iban|
    #    email|phone|telephone|mobile|dob|birth|passport|bearer|session|pin|pan/i
    # `pass` covers password/passwd/pass_code/passkey/passphrase; `cookie` covers set-cookie;
    # `credit`+`card` cover credit_card; `phone` covers telephone/smartphone; `birth` covers
    # date_of_birth. Substring match → favors over-redaction (privacy-by-default):
    # e.g. `company_name` (contains `pan`) or `shipping` (contains `pin`) get redacted — that is
    # acceptable, better to redact too much than to leak PII.
    # CYRB-3: the list omitted email/phone/dob → slow query binds leaked them into the panel.
    DENYLIST = %w[
      pass secret token api_key apikey authorization
      cookie csrf credit card cvv ssn iban
      email phone telephone mobile dob birth passport bearer session pin pan
    ].freeze

    # CYRB-23 — BUILT-IN redaction of authentication credentials in free text.
    # `filter_params`/`filter_value` cover STRUCTURED headers (the `authorization` key is in
    # DENYLIST); an `Authorization: Bearer <token>` pasted into `exception.message` or into a log
    # line is text, not a key, and before this ticket it was sent in clear because `scrub_message`
    # applied only the user-configured patterns (default `[]`).
    #
    # Shape of the redacted text (decided here once for all SDKs — twins CYDA-26/CYJS-38/
    # CYPY-15): key and scheme stay readable, ONLY the credential disappears →
    # `Authorization: Bearer [FILTERED]`. The message stays useful for diagnosis (you see THAT
    # there was a header and with which scheme) without carrying the secret.
    AUTH_SCHEME = /(?i:Bearer|Basic|Token)/

    # `token68` (RFC 7235) with trailing `=` padding: the shape of a real credential. Minimum 4
    # characters — a `Basic` with short credentials is short (`dTpw` = `u:p`); filtering out prose
    # is NOT_PROSE's job, not the length's.
    CREDENTIAL_TOKEN = %r{[A-Za-z0-9\-._~+/]{4,}={0,2}}

    # False-positive guard for the BARE scheme: what follows is NOT a credential if it has the shape
    # of a human-written word, i.e. letters only in ONE of three forms — `lowercase`, `Capitalized`,
    # `UPPERCASE` — and shorter than 20 characters. It spares "the bearer of bad news",
    # "invalid bearer credentials", "Basic HTTP authentication", "Bearer Token expired".
    # Everything else is a credential: entropy (digits, `_`, `-`, `.`), mixed inner capitals
    # (`dTpw`, base64) or length ≥ 20 (no word is that long, while an opaque lowercase-only token is).
    # Accepted trade-off: a CamelCase word right after the scheme (`Token MyAppName`) gets redacted.
    PROSE_WORD = /(?:[a-z]{1,19}|[A-Z][a-z]{0,18}|[A-Z]{1,19})/
    NOT_PROSE = %r{(?!\[FILTERED\])(?!#{PROSE_WORD}(?![A-Za-z0-9\-._~+/=]))}

    # Value of a header pasted into text: a sequence of non-delimiter pieces, where a quoted string
    # counts as ONE piece. NOT `\S+`, which would eat the `)` of "(Authorization: Bearer <token>)";
    # but not a plain class either, which would stop at the first quote leaving in clear the secret
    # of `Token token="<token>"` (RFC 7235 syntax and Rails' `authenticate_with_http_token`) and of a
    # JSON fragment pasted into the message.
    QUOTED = /"[^"\n]*"|'[^'\n]*'/
    HEADER_VALUE = /(?:#{QUOTED}|[^\s,;)\]}"'<>])+/

    # `Authorization:`/`authorization=` (also `Proxy-Authorization`, also `authorization_header`)
    # followed by the value: here the key is explicit, so it is redacted without prose heuristics —
    # intentional over-redaction, consistent with the DENYLIST. `[ \t]` not `\s`: never past newline.
    # The lookahead covers the OPTIONAL scheme: without it, on already redacted text the engine would
    # backtrack onto the "no scheme" branch and redact the word `Bearer` itself (not idempotent).
    AUTH_HEADER = /((?i:(?:proxy[_-]?)?authorization)[\w-]*["']?[ \t]*[:=][ \t]*)(?!(?:#{AUTH_SCHEME}[ \t]+)?\[FILTERED\])(#{AUTH_SCHEME}[ \t]+)?#{HEADER_VALUE}/

    # Bare scheme (`Bearer <token>` without the header name) followed by something shaped like a
    # credential: here the prose guard is needed, the word "bearer" shows up in messages.
    AUTH_CREDENTIAL = /(\b#{AUTH_SCHEME}[ \t]+)#{NOT_PROSE}#{CREDENTIAL_TOKEN}/

    DOLLAR_LITERAL = /\$([A-Za-z_][A-Za-z0-9_]*|)\$.*?(?:\$\1\$|\z)/m
    STRING_LITERAL = /'(?:[^']|'')*'/
    NUMERIC_LITERAL = /(?<![\w$])\d+(?:\.\d+)?\b/

    def initialize(configuration)
      @configuration = configuration
    end

    # Recursively filters Hash/Array replacing the values of sensitive keys.
    def filter_params(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), acc|
          acc[key] = sensitive_key?(key) ? FILTERED : filter_params(val)
        end
      when Array
        value.map { |item| filter_params(item) }
      else
        value
      end
    end

    # Masks the (string/numeric) literals in SQL, preserving the structure.
    def obfuscate_sql(sql)
      return sql if sql.nil? || !@configuration.obfuscate_sql

      sql.to_s.gsub(DOLLAR_LITERAL, "?").gsub(STRING_LITERAL, "?").gsub(NUMERIC_LITERAL, "?")
    end

    # Built-in rule (authentication schemes) BEFORE the user patterns: the two protections add up,
    # the first cannot be disabled — privacy-by-default (CYRB-23).
    def scrub_message(message)
      return message if message.nil?

      redacted = message.to_s
                        .gsub(AUTH_HEADER, "\\1\\2#{FILTERED}")
                        .gsub(AUTH_CREDENTIAL, "\\1#{FILTERED}")

      @configuration.scrub_message_patterns.reduce(redacted) do |acc, pattern|
        acc.gsub(pattern, FILTERED)
      end
    end

    # Value of a single bind/argument: redacted when the name (column/parameter) is sensitive.
    def filter_value(key, value)
      sensitive_key?(key) ? FILTERED : value
    end

    private

    def sensitive_key?(key)
      normalized = normalize(key)
      return true if DENYLIST.any? { |token| normalized.include?(normalize(token)) }

      @configuration.filter_parameters.any? do |param|
        param.is_a?(Regexp) ? param.match?(key.to_s) : normalized.include?(normalize(param))
      end
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end
  end
end
