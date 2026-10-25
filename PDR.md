# PDR — Gemma `closeyourit-ruby` (client telemetria "tipo Sentry")

> Documento di design + work breakdown + milestone di verifica per la creazione della gemma client.
> Il backend ingest CloseYourIt è la controparte: qui è trattato come **contratto esterno** (§13).

> **Stato v0.2.0 — client primario (parità + oltre sentry-ruby).** Oltre a eccezioni/slow-query/slow-method,
> la gemma cattura ora: **request context** (Rack middleware), **scope per-richiesta/job** (`set_user`/
> `set_tag`/`set_context`/`set_extra`/`configure_scope`), **breadcrumbs** (auto SQL offuscato + `add_breadcrumb`),
> **errori ActiveJob/Sidekiq** e **handled** (`Rails.error.report`), **`capture_message`**, **sampling**
> (`sample_rate`), **ignore per Regexp** e **release detection** automatica. Linea ingest unica = Bearer
> `/api/v1/projects/:id/{events,metrics}` (formato evento Sentry-shaped, additivo: fingerprint invariato).

---

## 1. Overview

`closeyourit-ruby` è una gemma che un progetto Rails installa per inviare la propria **telemetria** a
CloseYourIt (che fa da server, come GlitchTip). Modellata su `sentry-ruby` 6.6.2. Cattura:

- **Eccezioni** (come Sentry): Rack middleware + Rails error reporter.
- **Query lente** (`sql.active_record` oltre soglia).
- **Metodi lenti** (helper `measure{}` + macro `monitor`).

Invio **fire-and-forget** (thread pool, non blocca la request, non crasha mai l'app) verso
`POST <endpoint>/api/v1/ingest` con `Authorization: Bearer <token-progetto>` e body JSON.

## 2. Obiettivo & Motivazione

Sentry/GlitchTip fanno bene gli **errori** ma male le **statistiche di query/metodi lenti** (servirebbe
APM completo con `traces_sample_rate` + span; GlitchTip ha supporto performance limitato). Una gemma
focalizzata + payload JSON su misura dà il valore voluto con complessità minima e fa confluire **errori +
slow-stats** in un unico tool interno (CloseYourIt).

## 3. Scope

**In scope:** cattura eccezioni + slow query + slow method; trasporto async fire-and-forget; configurazione
block; no-op senza token; **gestione PII completa (§9)**; integrazione Rails; suite RSpec; README + initializer.

**Out of scope (futuro, §15):** context-lines stacktrace, gzip/retry/rate-limit/batching transport,
Hub/Scope thread-local, tracing distribuito, pubblicazione RubyGems, UI/dashboard/rotazione token backend.

## 4. Compatibilità & dipendenze

- **Ruby ≥ 4.0** (allineato a `closeyourit-rails`). Funziona anche **senza Rails** (plain Ruby:
  `capture_exception`, `measure`). Con Rails ≥ 7.1 si attivano Railtie/middleware/subscriber.
- Runtime dep: **`concurrent-ruby`** (thread pool). Stdlib: `net/http`, `json`, `securerandom`, `zlib` (futuro).
- Dev dep: `rspec`, `webmock`, `simplecov`, `rubocop-rails-omakase`, `rake` + mini-app Rails per i test integration.

## 5. Riferimento architetturale (mapping `sentry-ruby` 6.6.2)

| Oggetto gemma | Modello Sentry | Cosa prendere |
|---|---|---|
| `Configuration` | `configuration.rb` | block init, `before_send`, `excluded_exceptions`, gating env/sample |
| `Transport` | `transport/http_transport.rb` (`send_data`) | `Net::HTTP::Post` + header + rescue. Semplificato: Bearer, no envelope/gzip |
| `BackgroundWorker` | `background_worker.rb` | `Concurrent::ThreadPoolExecutor(max_queue:, fallback_policy: :discard)` + `perform{}` rescue |
| `ErrorEvent` | `error_event.rb` + `interfaces/single_exception.rb` + `interfaces/stacktrace.rb` | type/value/frames/causes/mechanism, **`backtrace_locations`** (no regex) |
| `capture_exception` | `hub.rb` + `client.rb` | dedup via ivar, gating, dispatch async. Niente Hub/Scope |
| Rails integration | `rack/capture_exceptions.rb` + `tracing/active_record_subscriber.rb` | middleware `rescue=>e;capture;raise` + subscriber `sql.active_record` |

## 6. Design — moduli

```
closeyourit-ruby/
├── closeyourit-ruby.gemspec            # dep: concurrent-ruby
├── Gemfile · Rakefile · .rspec · .gitignore · README.md · LICENSE.txt · PDR.md
├── lib/
│   ├── closeyourit-ruby.rb             # entry: require module + init/capture/measure/monitor
│   └── closeyourit/
│       ├── version.rb
│       ├── configuration.rb            # opzioni + default + no-op + validazioni
│       ├── client.rb                   # event_from_exception, capture (gating + scrub + dispatch)
│       ├── background_worker.rb        # thread pool fire-and-forget (sync se threads==0)
│       ├── transport.rb                # Net::HTTP POST Bearer + rescue + HTTPS guard
│       ├── event.rb                    # base, to_h non-nil
│       ├── events/{error_event,slow_query_event,slow_method_event}.rb
│       ├── scrubber.rb                 # PII: filtra params, normalizza SQL, denylist (§9)
│       ├── instrumenter.rb             # measure(label){} CLOCK_MONOTONIC + monitor macro (prepend)
│       └── rails/{railtie,capture_exceptions}.rb
└── spec/                               # RSpec + WebMock (unit + integration mini-app Rails)
```

## 7. API pubblica

```ruby
CloseYourIt.init do |c|
  c.endpoint_url             = ENV["CLOSEYOURIT_ENDPOINT_URL"]   # https://app.closeyour.it
  c.token                    = ENV["CLOSEYOURIT_TOKEN"]          # token Ingest::Source del progetto
  c.environment              = Rails.env
  c.slow_query_threshold_ms  = 100
  c.slow_method_threshold_ms = 200
  c.send_pii                 = false                              # default
  c.obfuscate_sql            = true                               # default
  # c.filter_parameters += [/custom_secret/]
  # c.excluded_exceptions += %w[My::Boring::Error]
  # c.before_send = ->(payload) { scrub(payload) }                # ritorna payload o nil
end

CloseYourIt.capture_exception(e)
CloseYourIt.measure("checkout.total") { slow! }
class Report; include CloseYourIt::Monitor; monitor :generate; end
```

Senza `token`/`endpoint` → **no-op totale**.

## 8. Contratto dati (payload JSON → backend)

Un POST = un evento (batch = array). Comuni: `kind`, `environment`, `occurred_at` (ISO8601),
`release` (opz.), `sdk` (`{name:"closeyourit-ruby", version:}`). **Nessun campo PII di default** (§9).

```jsonc
// kind=error
{ "kind":"error","environment":"production","occurred_at":"...",
  "exception":{ "type":"NoMethodError","value":"undefined method ...",
    "frames":[{"file":"app/models/x.rb","lineno":12,"function":"call","in_app":true}],
    "causes":[/* cause-chain, stessa forma */] },
  "mechanism":{"type":"rails","handled":false},
  "fingerprint":"<hash type + top in_app frame>" }

// kind=slow_query
{ "kind":"slow_query","environment":"...","occurred_at":"...",
  "duration_ms":248.5,"sql":"SELECT ... WHERE \"users\".\"id\" = $1",  // template, binds esclusi
  "name":"User Load","cached":false,"db_system":"postgresql" }

// kind=slow_method
{ "kind":"slow_method","environment":"...","occurred_at":"...",
  "label":"checkout.total","duration_ms":512.0,"file":"app/services/checkout.rb","lineno":40 }
```

---

## 9. PII & Data Privacy (dettaglio)

Principio: **privacy-by-default**. Allineato a `rules/logging.md` e al pattern `send_default_pii = false`
del backend. Master switch `send_pii` (default **false**).

### 9.1 Sorgenti di rischio e trattamento

| Sorgente | Rischio | Trattamento di default |
|---|---|---|
| **SQL** (`sql.active_record`) | bind = email/nomi/token | template SQL; **MAI** `payload[:binds]`/`:type_casted_binds`. `obfuscate_sql=true` maschera literal inline |
| **Messaggio eccezione** (`e.message`) | input utente | inviato (debug) **ma** passabile a `before_send`/`scrub_message_patterns` |
| **Request context** (URL/params/header/IP) | query/body/Cookie/Authorization/IP/user | `send_pii=false`: query/body/IP **non** allegati; Cookie/Authorization mai. Con `send_pii=true` il body (`capture_request_body`) passa dallo `Scrubber` (denylist + filter_parameters) |
| **Frame-local variables** | grande superficie PII | **MAI inviate** |
| **Argomenti di metodo** (`measure`/`monitor`) | args = PII | Non catturati (solo durata + label) salvo `capture_method_arguments` (opt-in): `inspect` troncato + `Scrubber` (chiavi sensibili, schemi di autenticazione, `scrub_message_patterns`) |
| **`server_name`/hostname** | infra | `send_server_name` (true) — solo hostname |
| **Token ingest** | secret | solo header `Authorization` su HTTPS, **MAI** nel body/log |

### 9.2 Scrubbing — `CloseYourIt::Scrubber`

- **Normalizzazione SQL** (`obfuscate_sql`): literal stringa/numerici → placeholder; bind AR sempre esclusi.
- **Denylist hardcoded** (case-insensitive, → `[FILTERED]`): `password, passwd, secret, token, api_key,
  apikey, authorization, cookie, set-cookie, csrf, credit_card, card, cvv, ssn, iban`.
- **`filter_parameters`**: la Railtie unisce `Rails.application.config.filter_parameters` (stringhe, simboli, regexp; i proc sono scartati) dopo i config initializers, così `CloseYourIt.init` non li perde.
- **`before_send`** (Proc): ultima chance sul payload scrubato; ritorna payload o `nil`.
- **`scrub_message_patterns`**: Regexp su `exception.value`.

### 9.3 Trasporto sicuro

- **HTTPS enforcement**: `http://` in `production` → **no-op + warn**; in `development` consentito con warn.
- Token mai loggato; payload mai loggato in `production`.

### 9.4 Rischio residuo (README)

`exception.value` e nomi tabella/colonna SQL possono contenere dati di dominio → `before_send`/
`scrub_message_patterns`. Niente frame-locals; body request e argomenti di metodo solo opt-in (`send_pii`,
`capture_method_arguments`): superficie PII minima per costruzione.

---

## 10. Requisiti non-funzionali

- **Mai crashare l'app**: capture/transport/worker in `rescue Exception` → log only.
- **Non bloccare la request**: async thread pool; coda bounded `discard`.
- **No-op sicuro** senza token/endpoint. **Anti-loop** (escluse eccezioni interne). **Dedup** via ivar.
- **Overhead subscriber minimo** (solo confronto soglia; build+scrub nel worker). **Soglie X-1/X/X+1**.

## 11. Strategia di test (RSpec + WebMock, gate ≥90% line)

Unit: Configuration, Transport, BackgroundWorker, ErrorEvent.from_exception, slow events, Scrubber.
Integration (mini-app Rails): middleware, subscriber `sql.active_record`, measure/monitor. WebMock blocca la rete.

---

## 12. MILESTONE (verificabili) — TDD, spec prima

- **M1 Configuration + no-op** — init block; no-op senza token; excluded default; http:// prod → no-op+warn.
- **M2 Transport + BackgroundWorker** — 1 POST Bearer+JSON (WebMock); errore rete non solleva; sync se threads=0; coda satura discard.
- **M3 Error capture + dedup** — type/value/frames/causes/fingerprint/mechanism; doppia cattura=1; excluded=0; before_send nil=0.
- **M4 PII/Scrubber** — denylist→[FILTERED]; SQL normalizzato; bind AR mai presenti; before_send ultimo; send_pii=false no IP/cookie/auth.
- **M5 Rails middleware** — eccezione → ri-solleva + invia kind=error; RoutingError/RecordNotFound no.
- **M6 Slow query** — soglia-1/soglia/soglia+1; SCHEMA/CACHE skip; payload slow_query; nessun bind value.
- **M7 Slow method** — measure sopra soglia → slow_method; sotto → 0; return invariato; monitor preserva firma; args mai inviati.
- **M8 README + dogfood E2E** — README (PII/rischi) + `.env.example`; in closeyourit-rails dev → `Ingest::Event` cresce, privo di PII.

> **Gate finale**: milestone verdi + `bundle exec rspec` ≥90% line + `rubocop` pulito.

## 13. Dipendenza esterna — endpoint ingest backend (contratto)

`POST /api/v1/ingest` Bearer `<token Ingest::Source>`; singolo o array; `202 {data:{accepted:N}}`;
`401 {error:{code:"R401-INGEST-001"}}`; `422` malformato. Persistenza `Ingest::Event`
(kind/environment/occurred_at/duration_ms/fingerprint + `data` jsonb). Throttle rack-attack per-token.
M1–M7 sviluppabili con **WebMock**; backend reale serve a M8. Token MVP via `bin/rails console`.

## 14. Rischi & questioni aperte

PII (§9, rischio residuo documentato) · overhead subscriber · repo GitHub solo su conferma
(`rules/git.md`) · target Ruby 4.0.5/Rails 8.1 · CI gemma futura (infra "DA DEFINIRE").

## 15. Out of scope / fasi future

Context-lines · gzip/retry/rate-limit/batching · Hub+Scope · tracing distribuito · request-context attach ·
RubyGems publish · UI/dashboard/rotazione token · hardening token a digest · retention `ingest_events`.
