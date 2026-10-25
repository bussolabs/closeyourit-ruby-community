# CloseYourIt Ruby SDK

Official Ruby client for [CloseYourIt](https://closeyour.it), the open source tracker for errors,
logs, uptime and servers. Add the gem to a Rails application and it sends:

- **Exceptions**, in Sentry event format, to `/api/v1/projects/:id/events`: grouped and triaged in
  the error tracker.
- **Slow queries and methods**, to `/api/v1/projects/:id/metrics`: grouped by signature with
  duration aggregates.
- **Structured logs**, background job errors and metrics, handled errors and messages.

It adds request context, user, tags and breadcrumbs, sends in the background (never blocks a
request, never crashes the app), is a no-op until configured and keeps PII out unless you turn it on.

## Install

```ruby
# Gemfile
gem "closeyourit-ruby"
```

## Configuration

In CloseYourIt, create a token in **Member → Project → tokens**: you get the bearer secret (shown
once) and the project UUID.

```ruby
# config/initializers/closeyourit.rb
CloseYourIt.init do |c|
  c.endpoint_url = ENV["CLOSEYOURIT_ENDPOINT_URL"]   # https://app.closeyour.it, or your own installation
  c.token        = ENV["CLOSEYOURIT_TOKEN"]
  c.project_id   = ENV["CLOSEYOURIT_PROJECT_ID"]
  c.environment  = Rails.env
end
```

Without `endpoint_url`, `token` and `project_id` the gem does nothing. In `production` an `http://`
endpoint is refused, because the token would travel in clear text.

Full guide, with every option, slow queries, job metrics, forking servers and privacy:
[closeyour.it/docs/sdk-ruby](https://closeyour.it/docs/sdk-ruby).

## Development

```bash
mise install
bundle install
bundle exec rubocop
bundle exec rspec
```

## Contributing

Pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) and [CLA.md](CLA.md). This
repository is a published copy: accepted changes are applied to the upstream source and come back
here with the next release. Report vulnerabilities as described in [SECURITY.md](SECURITY.md).

## License

MIT, see `LICENSE.txt`.
