# Open Dashboard v1

Risposta di `GET /open-dashboard`: chi è il servizio, che versione gira e le sue metriche.
Regole complete: `commons/knowledge-base/global/open-dashboard.md`.

| Producer | Consumer |
|---|---|
| servizi Rails tramite la gem `closeyourit-ruby` | `closeyourit-rails` (pagina Dashboard) |

- Definizione da validare: `$defs/report`.
- «Una `key` per risposta» non si esprime in JSON Schema: lo controllano il verificatore sulle
  fixture valide e la gem alla configurazione.
- Il lettore ignora i campi che non conosce: aggiungerne uno facoltativo è `1.x`.
