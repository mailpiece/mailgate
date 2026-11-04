# Instrument

This page describes the instrument, an optional hook on both listeners for metrics. For the calls that store
and score mail, see [Backend](backend.md) and [Scorer](scorer.md).

The code lives in [lib/mailgate/listener.rb](../lib/mailgate/listener.rb).

The hook is called as `instrument.call(event, **data)`, from the connection's own thread (or the accepting
thread, for one refusal), so it must be quick and safe across threads.

```ruby
MailGate::MxListener.new(backend:, instrument: ->(event, **data) { Metrics.increment("mailgate.#{event}", **data) }, ...)
```

Without one, mailgate only checks for nil. An error it raises goes to the backend's `report_error`, and the
SMTP session carries on.

The data is plain: symbols, numbers, strings and the client's IP. Never message content, addresses,
credentials or account ids. `duration` is in seconds.

| Event | Listener | Data |
|---|---|---|
| `:connection_accepted` | both | `ip` |
| `:pregreet_refused` | MX | `ip`; the client talked before the banner and got a 554 |
| `:reverse_dns_finished` | MX | `ip`, `outcome`, `duration`; sent when the message first needs the name |
| `:scorer_finished` | MX | `ip`, `queue_id`, `action`, `score`, `duration`; `score` is nil for a verdict without one |
| `:scorer_failed` | MX | `ip`, `queue_id`, `error`, `duration`; `error` is the class name |
| `:message_accepted` | both | `ip`, `queue_id`, `bytes`, `recipients` |
| `:auth_succeeded` | submission | `ip` |
| `:auth_failed` | submission | `ip` |
| `:rate_limited` | both | `ip`, `limit` |
| `:connection_refused` | both | `ip`, `limit`; a 421 at `:max_connections` or `:max_connections_per_ip` |
| `:error_tarpitted` | both | `ip`, `duration`; an error reply held back past `soft_error_limit` |
| `:error_limit_reached` | both | `ip`; the 421 at `hard_error_limit`, or at the first error under stress |
| `:replied` | both | `ip`, `code`; each reply sent, with its numeric code |

`outcome` is `:verified` for a forward-confirmed name, `:unknown` when there is no PTR or it does not resolve
back, and `:temporary_failure` for anything else: a DNS failure, a timeout, a resolver error or
`max_connections` lookups already running.

For `:rate_limited`, `limit` is `:messages_per_ip` (450 at MAIL FROM), `:tls_sessions_per_ip` (454 at
STARTTLS) or `:auth_attempts_per_ip` (454 at AUTH), `:processings_per_ip` (451 at DATA), or `:account` for the
submission backend's `rate_limited?` (452 at MAIL FROM).

`:connection_refused` at `:max_connections` is sent from the accepting thread, before there is a connection
thread or a session; behind PROXY its `ip` is the proxy's, and it is nil when the client was already gone. Its
421 is the one reply `:replied` does not see. `:replied` does see the 421 at `:max_connections_per_ip`, sent
before `:connection_accepted`.
