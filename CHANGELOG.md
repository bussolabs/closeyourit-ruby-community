# Changelog

Tutte le modifiche degne di nota a questo progetto sono documentate qui.

Il formato si basa su [Keep a Changelog](https://keepachangelog.com/it/1.1.0/)
e il progetto aderisce al [Semantic Versioning](https://semver.org/lang/it/).

## [Unreleased]

## [0.13.0] - 2026-10-25

### Aggiunto

- **Open Dashboard.** Con `CloseYourIt::OpenDashboard.configure` il servizio mostra i suoi numeri su `GET /open-dashboard`, protetto da una chiave. CloseYourIt li legge e li mette in una sola pagina. (CYRB-29)

## [0.12.1] - 2026-10-07

### Corretto

- **La 0.12.0 non è arrivata su RubyGems.** Questa versione contiene le stesse modifiche.

## [0.12.0] - 2026-10-07

### Corretto

- **Il body della richiesta resta a casa senza `send_pii`.** Con la privacy spenta i parametri dei form non vengono più allegati agli errori, come promesso dalla documentazione. Chi li vuole attiva `send_pii`. (CYRB-28)
- **I filtri di Rails valgono anche per la gemma.** Le chiavi dichiarate in `config.filter_parameters` dell'app vengono redatte in errori, tag e metriche senza ripeterle nella configurazione. (CYRB-28)
- **Argomenti dei metodi lenti redatti.** Con `capture_method_arguments` anche gli argomenti posizionali passano dallo scrubber dei messaggi (credenziali e `scrub_message_patterns`). (CYRB-28)

## [0.11.0] - 2026-10-04

### Aggiunto

- **Contesto dei tentativi di lavoro.** ActiveJob e Sidekiq inviano il contesto job v1 con durata, attesa e ritardo programmato separati. Tempi o esiti non osservabili restano sconosciuti. (CYRA-972)
- **Log del ciclo di vita dei job.** L'opzione `job_lifecycle_logs`, spenta per default, registra gli esiti osservati senza argomenti o risultati e senza duplicare ActiveJob dentro Sidekiq. (CYRA-972)

### Corretto

- **SQL protetto anche con stringhe dollar-quoted.** I valori PostgreSQL racchiusi fra delimitatori dollar-quoted vengono redatti prima dell'invio della telemetria.

## [0.10.2] - 2026-10-01

### Corretto

- **Pubblicazione riparata.** La 0.10.1 non è arrivata su RubyGems: questa versione contiene le stesse modifiche.

## [0.10.1] - 2026-10-01

### Modificato

- **Le query dell'app costano meno.** Il punto del codice da cui parte una query si calcola solo per quelle lente o da analizzare, non più per ogni query. (CYRB-26)

### Corretto

- **L'attesa in coda dei lavori non conta più i rinvii voluti.** Un lavoro rimandato apposta, o ritentato dopo un errore, risultava in ritardo anche se partiva puntuale. Ora l'attesa si misura dall'ora prevista di partenza. (CYRB-27)

## [0.10.0] - 2026-09-14

### Aggiunto

- **Si sceglie quanto attendere alla chiusura.** Nuova opzione `shutdown_timeout`: dice quanto tempo dare all'invio degli eventi rimasti prima di chiudere. (CYRB-24)

### Corretto

- **Alla chiusura del programma gli eventi in coda non si perdono più in silenzio.** L'attesa era troppo corta e l'ultimo gruppo spariva, dato per consegnato. Ora l'attesa basta a completare l'invio e ciò che resta indietro viene contato. (CYRB-24)
- **Un messaggio malformato non porta più via gli altri.** In un gruppo di voci di registro viene scartata solo quella che dà problemi: le altre partono. (CYRB-24)
- **La misurazione dei tempi non fa più fallire il metodo dell'applicazione.** Un guasto interno alla misurazione tornava a chi aveva chiamato il metodo. Ora viene registrato e assorbito. (CYRB-24)
- **I controlli automatici tornano a girare su ogni proposta di modifica.** Le verifiche erano ferme e le modifiche passavano senza prova. Ora ogni proposta viene controllata prima di essere unita. (CITM-8)

## [0.9.4] - 2026-09-07

### Corretto
- **La credenziale nel testo di un messaggio non parte più in chiaro** (CYRB-23). Un
  `Authorization: Bearer …` finito in un errore o in un log ora è redatto di serie, senza
  configurazione: restano leggibili chiave e schema, sparisce il valore.
- **Il token non segue più un redirect su un'altra porta** (CYRB-22). Un redirect che teneva lo stesso
  nome host ma cambiava porta riceveva ancora il `Bearer`: sullo stesso server è un servizio diverso.
  Ora l'invio richiede stesso host, stessa porta e schema non degradato.

## [0.9.3] - 2026-09-03

### Modificato
- **Il README dice dove finisce la gemma e dove iniziano gli altri SDK** (CYRB-21). Non lascia più
  intendere di fare le stesse cose di JavaScript, Dart e Python: dice cosa esiste solo qui e rimanda
  alla tabella unica di cosa c'è dove
  ([`sdk-feature-parity.md`](https://github.com/bussolabs/closeyourit-docs/blob/main/compatibility/sdk-feature-parity.md)).

## [0.9.2] - 2026-08-31

### Corretto
- **`CloseYourIt.used` è davvero chiamabile.** Il punto d'ingresso della telemetria d'uso era
  finito per sbaglio fra i metodi interni; e due rami senza prova tenevano il rilascio sotto la
  soglia di copertura. La 0.9.1 esiste come etichetta ma non è mai stata pubblicata.

## [0.9.1] - 2026-08-31

### Corretto
- **Il rilascio non si ferma più su se stesso.** Il controllo che confronta l'etichetta del rilascio
  col numero dentro la libreria aveva quel numero scritto a mano nei propri test: ogni aggiornamento
  li faceva diventare rossi. Ora lo leggono dalla libreria. La 0.9.0 esiste come etichetta ma non è
  mai stata pubblicata: si è fermata qui.

## [0.9.0] - 2026-08-31

### Aggiunto
- **Telemetria d'uso (CYSK-29)**: la gemma dichiara quali rotte (`Controller#action`, mai l'URL),
  job e chiavi custom (`CloseYourIt.used("chiave")`) vengono davvero eseguiti — un flush ogni 5
  minuti per processo verso `/api/v1/projects/:id/usages`. I conteggi sono indicativi, solo
  `last_seen_at` è portante; oltre `usage_max_symbols` (2000) il flush dichiara `truncated`, che
  lato scanner squalifica il kind. Nessun dato utente nel payload per costruzione. Interruttori:
  `usage_enabled` (default ON), `usage_flush_interval`, `usage_max_symbols`.

### Sicurezza
- **Non si pubblica più una versione col nome di un'altra**: prima di toccare RubyGems il rilascio
  confronta il numero scritto sull'etichetta con quello scritto dentro la libreria, e li pretende
  identici lettera per lettera. Finora non li guardava nessuno: `rake release` pubblicava il numero
  del gemspec qualunque cosa dicesse l'etichetta, e quando poi bundler cercava fra i tag quello che
  aveva appena pubblicato non lo trovava — così se lo creava da solo. Nasceva un rilascio che nessuna
  persona aveva deciso, e il giro finiva verde. Adesso si ferma prima, e scrive quali sono i due
  numeri che non tornano. Il confronto è fra stringhe di proposito: per le regole delle versioni Ruby
  `0.8` e `0.8.0` sono lo stesso numero, ma chi legge l'annuncio di una `0.8` cercherebbe su RubyGems
  una versione che non esisterà mai.
- **Hardening della supply chain CI** (CYRB-16): le action di terze parti (`actions/checkout`,
  `ruby/setup-ruby`, `rubygems/release-gem`) sono ora fissate al **commit SHA** con il tag versione a
  commento, non più a un tag mobile che l'owner può ripuntare a un commit arbitrario; i workflow
  dichiarano permessi **least-privilege** (`contents: read` di default, `write` + `id-token` solo nel
  job che pubblica); Dependabot presidia gemme di sviluppo e action tenendo i **major come PR
  separate**. Nessun impatto sul runtime della gemma (`concurrent-ruby` invariato): cambia solo come la
  CI si costruisce. Un nuovo spec "meta" (`ci_hardening_spec`) impedisce di reintrodurre un riferimento
  mutabile o un token troppo ampio.

## [0.8.0] - 2026-08-01

### Aggiunto
- **Propagazione del trace context W3C** (CYRB-15): opt-in (`propagate_trace_context`, default OFF) per
  correlare le richieste Ruby e le chiamate in uscita con lo standard
  [W3C Trace Context](https://www.w3.org/TR/trace-context/) (`traceparent`/`tracestate`), senza formato
  proprietario. In **ingresso** un `traceparent` valido diventa il `trace_id` degli eventi CloseYourIt, così
  errore e metrica della richiesta si allineano alla traccia distribuita; un header malformato viene ignorato
  e si genera un root. In **uscita** gli header sono iniettati **solo** verso gli host di
  `trace_propagation_allowlist` (default vuoto = nessuna destinazione), mai verso l'endpoint CloseYourIt né
  verso host esterni; un redirect verso un host non elencato non riceve nulla. `baggage` non viene mai emesso.

### Corretto
- **Un errore ritentato non è più segnalato una volta per tentativo** (CYRB-19): l'`around_perform` che
  cattura gli errori dei job gira **dentro** `perform_now`, mentre `retry_on`/`discard_on` (rescue_from)
  sono valutati **fuori**, dopo i callback — così ogni tentativo veniva segnalato come errore non gestito
  (e ogni tentativo solleva una nuova istanza, quindi la deduplica per-istanza non interviene). Un errore
  passeggero che si risolveva al secondo tentativo ne generava comunque due, gonfiando conteggi, allarmi e
  corsa verso i limiti (sul campo: 2.033 eventi *rate limited*, il 74,7% erano ripetizioni di retry). Su
  ActiveJob **7.1+** la segnalazione passa ad `after_discard`, invocato da Rails al fallimento definitivo,
  mai sui tentativi che `retry_on` ritenta: un `retry_on` riuscito non produce errori, un `retry_on`
  esaurito produce **una sola** occorrenza — con i breadcrumb e i tag raccolti durante l'esecuzione
  preservati nel report. Sulle versioni prive di `after_discard` resta il comportamento precedente (fallback
  legacy). Due conseguenze da conoscere: gli errori intercettati da un `rescue_from` **custom** non sono più
  segnalati (sono gestiti dall'app: prima li marcavamo impropriamente come non gestiti); i retry a livello
  di **adapter** (es. Sidekiq) senza `retry_on` risollevano l'errore non gestito e restano quindi segnalati
  a ogni esecuzione, come prima.

## [0.7.0] - 2026-07-30

### Aggiunto
- **Metriche dei background job** (CYRB-14): `slow_job` (durata del `perform` oltre soglia) e
  `job_queue_latency` (attesa enqueue→esecuzione oltre soglia) per ActiveJob e Sidekiq, come metriche
  `performance_issue`. Ogni metrica porta `label` (nome della classe del job — **mai** gli argomenti),
  `queue`, `adapter`, `attempt` (i retry diventano visibili), `release` e `trace_id` (`job_id`/`jid`),
  così log ed errore dello stesso job si correlano. Nuove opzioni `monitor_jobs` (ON di default:
  vedere i job lenti non deve richiedere strumentazione manuale in ogni app), `slow_job_threshold_ms`
  (5000), `job_queue_latency_threshold_ms` (60000), `jobs_sample_rate` (1.0). Il middleware Sidekiq
  ri-solleva sempre gli errori del job ospite: la telemetria è isolata.
- **Hook diagnostico `on_diagnostic` + contatori estesi** (CYRB-12): `->(event, details)` opt-in,
  invocato a ogni tappa del ciclo di vita di un evento (`:enqueue`, `:send`, `:drop`, `:timeout`,
  `:shutdown`) con dettagli privi di dati sensibili. È **locale e non ricorsivo**: non invia
  telemetria, quindi non può innescare un loop di auto-monitoraggio. Nuovo contatore `timeout` (come
  sotto-conteggio di `failed`) e alias `snapshot` su `Stats`.
- **`CloseYourIt.after_fork`** (CYRB-11): hook per i worker dei server che precaricano l'app.
- **Config `excluded_log_patterns`** (default `[]`): righe del broadcast `Rails.logger` da scartare in
  base al **testo**, per il rumore ripetuto che non è un'eccezione e che quindi `excluded_exceptions`
  non può coprire (es. `/SolidQueue-[\d.]+ Error in thread/`). I `Regexp` valgono come pattern, le
  `String` come testo letterale (vengono escapate: chi scrive `"Error in thread (0.0ms)"` non si
  aspetta che parentesi e punto siano metacaratteri).
- **Predicato pubblico `CloseYourIt.ignored_log_message?(text)`**: risponde se una riga di log va
  scartata secondo `excluded_exceptions` + `excluded_log_patterns`. Reso pubblico per lo stesso motivo
  di `logs_active?` — serve a un collaboratore (`LogBroadcast`) per non fare lavoro inutile.
- **Config `excluded_query_patterns`** (CYRB-18): query da **non** misurare come rallentamento, match
  sul testo SQL. Default **non vuoto**: `solid_queue_`, `solid_cache_`, `solid_cable_`. Le tabelle di
  servizio del Solid stack sono infrastruttura del framework — una loro query lenta non si corregge
  leggendo il proprio repo, dice solo che il database è in contesa (cosa che le query dell'app
  raccontano già), e in compenso sommerge il segnale utile: su closeyourit-rails il 2026-07-30 erano
  circa **2.740 campioni su 4.400 (62%)**, tutti fra i 250 e i 655 ms. Chi vuole misurarle azzera la
  lista. `\b` in testa a ogni pattern: una tabella dell'app che contenga `queue` nel nome non sparisce
  per assonanza.

  Il filtro vale solo per la **misura**, non per `#breadcrumb` né per `#profile`: la cronologia «quali
  query prima del crash» resta completa (nasconderne un pezzo la renderebbe bugiarda) e il profiling
  N+1 continua a vedere tutto, perché lì una tabella di servizio letta molte volte è essa stessa un
  sintomo. Un rallentamento va misurato se qualcuno può intervenire; una breadcrumb va tenuta se aiuta
  a capire — due domande diverse.

### Corretto
- **La gemma riparte nel processo figlio dopo un fork** (CYRB-11): i server che precaricano l'app (Puma
  cluster, Sidekiq, Unicorn) inizializzano la gemma nel master e poi forkano. Il worker pool e il
  `TimerTask` del buffer sono **thread**, e i thread non sopravvivono al fork: nel figlio `@client` e
  `@log_buffer` erano ereditati ma **inerti**, e nessun evento partiva più. Ora il cambio di PID viene
  rilevato (lazy, al primo accesso) e le risorse ricreate nel processo corrente. I riferimenti
  ereditati vengono abbandonati **senza** shutdown né drain: nessun join sui thread del padre, e
  nessun flush del suo buffer — rispedirebbe eventi che non sono di questo processo.
- **Re-inizializzare non perde più gli eventi in coda** (CYRB-10): `init` azzerava `@client` e
  `@log_buffer` senza spegnerli, lasciando orfani il thread del worker pool e il `TimerTask`; gli
  eventi accodati venivano persi, o flushati fuori tempo con la **vecchia** credenziale. Ora `init`
  applica al client precedente la semantica di fine-vita di `#shutdown` (flush del buffer → drain del
  worker con timeout) prima di sostituirlo. Idempotente.
- **La gemma si installa davvero su Ruby 4.0** (CYRB-13): la CI la provava solo dentro il proprio
  bundle, dove le stdlib estratte e `rack` arrivano da altre gemme — un'app reale che installava solo
  `closeyourit-ruby` su Ruby 4.0 **falliva il `require`**. Il gemspec ora dichiara `logger` (da Ruby
  4.0 non è più una default gem) e `rack/utils` è caricato lazy dentro il middleware, così il require
  della gemma non forza `rack` nelle app non-web.
- **Nessun batch di log perso in silenzio** (CYRB-12): i log scartati da `before_send` incrementano
  `dropped` ed emettono `:drop` come già faceva `capture_event`, e un batch perso perché `flush_logs`
  solleva viene contabilizzato invece di svanire. `:shutdown` viene emesso una sola volta per sessione.
- **Il broadcast di `Rails.logger` rispetta `excluded_exceptions`** (CYRB-17): un'eccezione esclusa dal
  canale **errori** rientrava da quello dei **log**. Rails la registra comunque con `logger.error`, e
  `LogBroadcast#add` inoltrava la riga senza guardarne il testo — così il rumore che
  `excluded_exceptions` aveva appena scartato ricompariva come log-entry. Misurato sul backend il
  2026-07-30: **48.000 voci su 49.985** nello stream cross-app, quasi tutte
  `ActionController::RoutingError` da favicon mancanti e scansioni di bot, cioè una classe presente
  nelle esclusioni di **default** dalla prima riga della gemma. Il filtro guarda il testo (qui la
  classe arriva come stringa dentro il messaggio, non come oggetto con `ancestors`) e vive
  esclusivamente in `LogBroadcast`: un `CloseYourIt.log` scritto di proposito dallo sviluppatore non
  viene mai silenziato, perché chi lo scrive ha già deciso che vuole quella riga.
- **Il filtro copre anche la forma lazy `logger.error { ... }`**: il testo viene valutato **dopo** lo
  `yield`. Guardando solo l'argomento posizionale (che in quella forma è `nil`) ogni riga costruita
  lazy avrebbe scavalcato le esclusioni.

### Interno
- **La CI verifica la gemma su una matrice Ruby con smoke install isolato** (CYRB-13): minima **esatta**
  `4.0.0` (prima `"4.0"` installava l'ultima patch, lasciando la minima dichiarata non testata) più la
  corrente derivata da `.ruby-version`, così la matrice non diverge dal runtime. Nuovo step che
  costruisce la gemma e la installa in un `GEM_HOME` isolato verificando `require`, config no-op e API
  pubblica; la release dipende da questo gate su **tutte** le versioni.
- **Gate di branch coverage a 90** (CYRB-13): la sola line coverage (97%) mascherava rami difensivi mai
  esercitati — guardie no-op da client disabilitato, path `nil`, percorsi d'errore del transport.
  Portata da 84,5% a 90,7% e resa vincolante con `COVERAGE_ENFORCE=1`.
- Chiusi due rami mai esercitati di `LogBroadcast#add` (forma con block, messaggio assente): la branch
  coverage torna sopra il gate (**90,05%**), che si era riabbassato a **89,72%** su `main` dopo
  CYRB-14.
- **Uno spec di CYRB-14 passava solo dentro un git worktree**: `omette i campi nil` faceva
  `config.release = nil`, ma il reader `release` **auto-rileva** (tag, ENV di deploy, `git rev-parse`).
  `git_revision` si autoesclude quando `.git` non è una directory — vero in un worktree, dove `.git` è
  un file, **falso** in un checkout normale come quello di `actions/checkout`: lì `detect_release`
  restituiva lo short SHA e lo spec cadeva. Ora stubba il reader, perché quello che vuole verificare è
  l'assenza della release, non il modo in cui viene rilevata. Trovato preparando questa release: la CI
  non aveva mai girato su quei commit, mai pushati.

## [0.6.1] - 2026-07-11

### Corretto
- **`detect_release` preferisce il tag semver allo short SHA** (CYRB-9): l'auto-rilevamento della
  `release` usava solo le fonti SHA (`KAMAL_VERSION`/`GIT_SHA`/`GIT_REVISION`/`SOURCE_VERSION`/
  `HEROKU_SLUG_COMMIT`/`git rev-parse`), quindi allegava agli eventi il commit hash (es. `d3ce2af`)
  invece del tag semver (es. `v0.0.43`), creando release duplicate lato backend che non convergevano
  con quelle registrate dalla CI (che usa il tag). Ora `detect_release` legge prima un tag semver da
  `APP_GIT_TAG` poi `GIT_TAG` (accettato solo se non-blank e con forma `vX.Y.Z` + eventuale suffisso
  prerelease/build), con le fonti SHA come fallback invariato. Valori non-semver (`unknown`, vuoto,
  nomi di branch) vengono ignorati.

## [0.6.0] - 2026-07-10

### Aggiunto
- **Config `trap_signals`** (default `false`, opt-in): quando attiva, `CloseYourIt.init` intercetta
  `SIGTERM` e lo converte in un exit pulito, così il flush di fine-vita gira anche al deploy (Kamal
  invia `SIGTERM`, che di default salta gli `at_exit`). Opt-in perché sovrascrive un eventuale handler
  `TERM` dell'app ospite. Esposto anche il metodo pubblico `CloseYourIt.shutdown` per drenare a mano.

### Corretto
- **`capture_rails_logs` non inonda più lo stream col rumore del framework** (CYRB-7): il broadcast di
  `Rails.logger` usava `logs_min_level` (default `:info`) come soglia → in produzione ad alto traffico
  ogni riga info del framework (`Started GET`, `Rendered`, ...) veniva inoltrata, saturando lo stream.
  Ora la soglia del broadcast è governata dalla nuova opzione **`capture_rails_logs_min_level`** (default
  `:warn`, distinta da `logs_min_level`): il rumore info del framework resta fuori di default, chi lo
  vuole abbassa esplicitamente la soglia (es. `:info`). `logs_min_level` continua a governare
  `CloseYourIt.log`/`.logger`. Il README già prometteva la soglia `:warn` ma il codice non la applicava.
- **Flush di fine-vita affidabile (CYRB-5)**: allo shutdown del processo il buffer log ora **drena
  anche il worker asincrono** (`@client.shutdown` → `wait_for_termination`) dopo il flush, non solo
  accoda l'ultimo batch. Prima l'`at_exit` flushava il buffer nel worker pool ma non attendeva
  l'invio: i log sotto-batch (< `logs_batch_size`, timer non ancora scattato) restavano in coda e
  venivano persi alla terminazione. Vedi anche la nuova config `trap_signals` per il caso `SIGTERM`.
- **Denylist Scrubber allineata alla PII del backend** (CYRB-3): la `DENYLIST` dello Scrubber era più
  stretta del regex `SENSITIVE_KEY` del backend/Dart — i bind di query e metodi lenti su colonne
  `email`/`phone`/`dob` (e affini) NON venivano redatti e finivano nel pannello "Parametri" della
  metric-group, visibili a ogni viewer. Aggiunti i token `email phone telephone mobile dob birth
  passport bearer session pin pan`; il match per sottostringa privilegia l'over-redaction
  (privacy-by-default).
- **`capture_message` ora emette `trace_id`** (parità con `capture_exception`): i messaggi diagnostici
  si correlano ai log/errori della stessa richiesta come gli eventi d'errore (prima il `trace_id` era
  omesso e i messaggi restavano scollegati).
- **Sicurezza redirect**: il `Bearer` (segreto d'ingest) non viene più ri-inviato dopo un redirect verso
  un host diverso, né su un downgrade `https→http` — solo stesso host (o variante `www`) e schema non
  degradato. Evita di consegnare il token a un endpoint non fidato.
- **DX diagnostica**: su risposta non-2xx il log include ora il codice d'errore `R…` e il messaggio
  dall'envelope del backend (es. `HTTP 422 R422-INGEST-001: Evento malformato`), non solo lo status.

## [0.5.0] - 2026-07-08

### Aggiunto
- **Correlazione errore server ↔ session replay**: il middleware `RequestContext` legge il cookie
  `cyi_replay` (id opaco scritto dal browser SDK) e lo mette su `Scope#replay_session_id`; l'evento
  d'errore lo emette in `contexts.replay.replay_id` (stesso punto del percorso JS) → il backend lega
  il 500 al video della sessione. `replay`/`replay_id` non sono chiavi sensibili (sopravvivono allo
  Scrubber). Nessuna nuova config.

## [0.4.0] - 2026-07-02

### Aggiunto
- **Context lines nei frame dello stacktrace**: ogni frame con file sorgente leggibile porta
  `pre_context`/`context_line`/`post_context` (config `context_lines`, default 3, `0` disattiva;
  `LineCache` bounded e thread-safe). L'error show del backend renderizza già lo snippet.
- **Body della richiesta nell'evento (`request.data`)**: estratto LAZY solo quando l'errore accade
  (mai sul percorso felice) — preferisce i params già parsati da Rails/Rack, fallback rilettura
  `rack.input` con rewind (JSON/form, cap 64 KB). Sanitizzato (upload → `[FILE: …]`, oggetti →
  `[OBJECT: …]`, stringhe troncate a 1024) e scrubbato (denylist + `filter_parameters`); il backend
  ri-scruba difensivamente. Config `capture_request_body` (default true).

## [0.3.4] - 2026-06-29

### Aggiunto
- **Rilevamento performance issue lato client** (opt-in `detect_performance_issues`, default OFF):
  `Performance::RequestProfile` accumula per-richiesta le query (per fingerprint + call-site, stile
  prosopite) e le chiamate HTTP esterne; `Performance::Rollup` emette verdetti `n_plus_one` /
  `high_query_count` / `slow_request` / `slow_external_http` come `PerformanceIssueEvent`
  (kind `performance_issue`, con `trace_id`) verso `/metrics`. `trace_id` aggiunto anche a
  `SlowQueryEvent`.

### Corretto
- **`capture_rails_logs` non agganciava il broadcast** (i log dell'app non arrivavano a CloseYourIt):
  l'initializer del railtie `closeyourit.capture_rails_logs` girava **prima** di
  `config/initializers/closeyourit.rb` (dove `CloseYourIt.init` imposta `capture_rails_logs = true`),
  quindi leggeva il default `false` e non agganciava mai il broadcast di `Rails.logger`. Aggiunto
  `after: :load_config_initializers` all'initializer.

## [0.3.3] - 2026-06-29

### Corretto
- **Scrubber — chiavi `pass*`**: la denylist ometteva `pass` bare (`pass_code`, `passkey`,
  `passphrase`) → allineata 1:1 al regex di backend/Dart (parità client-side, niente leak).
- **Scope — `tags`/`extra`/`contexts` scrubbati client-side** prima dell'invio: il backend non li
  ri-scrubbava sugli errori, quindi era l'unica difesa contro le chiavi sensibili in quei campi.
- **Log — chunking del batch a `LOGS_MAX_BATCH` (1000)**: un flush oltre il limite del server veniva
  rigettato in blocco (413) coi log persi; ora è spezzato in più POST sequenziali.

## [0.3.2] - 2026-06-29

### Aggiunto
- **Log strutturati** verso l'ingest `/logs` di CloseYourIt:
  - `CloseYourIt.log(level, message, logger:, **attributes)` — costruisce e bufferizza una voce di log
    (livello normalizzato ai valori canonici del backend; `:warn` → `warning`).
  - `CloseYourIt.logger` — oggetto Logger-compatibile (`debug/info/warn/error/fatal`, `<<`, `add`) che
    inoltra a `CloseYourIt.log`. Usabile come logger esplicito dell'app, anche con attributes.
  - **Batching** in-memory thread-safe: flush a `logs_batch_size` (default 50), a `logs_flush_interval`
    (default 5s) o allo shutdown (`at_exit`); invio come array, fire-and-forget.
  - **Broadcast opt-in di `Rails.logger`** (`config.capture_rails_logs`, default OFF): re-inoltra i log
    dell'app ≥ `logs_min_level` (default `:info`). Richiede `BroadcastLogger` (Rails 7.1+).
  - Opzioni: `logs_enabled`, `logs_sample_rate`, `logs_batch_size`, `logs_flush_interval`,
    `capture_rails_logs`, `logs_min_level`. Gli `attributes` passano dallo `Scrubber` (denylist PII).
- **`trace_id`** per richiesta (`RequestContext`): riusa il request id di Rails/Rack se presente,
  altrimenti lo genera. Attaccato sia a `LogEvent` sia a `ErrorEvent` → correlazione log↔errori.

### Modificato
- Il logger diagnostico interno della gemma è ora `CloseYourIt.internal_logger` (prima `CloseYourIt.logger`);
  `CloseYourIt.logger` è riservato al logging applicativo strutturato.

## [0.3.1] - 2026-06-28

### Corretto
- `Transport`: segue fino a 2 redirect su POST preservando metodo + body (es. apex → www), così
  l'evento non si perde in silenzio quando l'host canonico risponde 301.

## [0.3.0] - 2026-06-28

### Aggiunto
- `CloseYourIt.stats`: contatori diagnostici thread-safe (`enqueued`, `dropped`, `sent`,
  `failed`) per rendere visibili i fallimenti silenziosi del trasporto fire-and-forget.
- Il trasporto ora logga a `warn` le risposte HTTP non-2xx (es. `401`, `404`, `500`),
  prima ignorate silenziosamente.
- Il background worker logga e conta gli eventi scartati quando la coda async è piena.
- `validate!` avvisa se `project_id` non ha forma UUID o se `endpoint_url` è privo di host.
- Scansione vulnerabilità delle dipendenze con `bundler-audit` nella CI.

### Modificato
- `.rubocop.yml`: `TargetRubyVersion` allineato a `4.0` (coerente con la gemspec).

## [0.2.0]

- Baseline: client di telemetria (eccezioni, query/metodi lenti, breadcrumbs, scope,
  sampling, scrubbing PII) con integrazione Rails/Sidekiq e trasporto fire-and-forget.
