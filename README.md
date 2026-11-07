# mailgate

🚪 A boring MX and submission server for Ruby.

Receive mail on port 25 and take submissions on port 587, with the policy a mail service needs. **mailgate**
runs the SMTP side on top of [mailsmtp](https://github.com/mailpiece/mailsmtp) and calls your backend for
storage, accounts and tokens, and your scorer for spam.

**mailgate** handles:

- an MX listener: recipients routed by your backend, one reply to DATA for every recipient
- a submission listener: AUTH checked by your backend, STARTTLS required, sender checks
- Authentication-Results and Received-SPF stripped from inbound mail, so a backend can't skip it
- a header section over 256 KB refused on both listeners
- loop detection on its own `Received:` stamps
- forward-confirmed reverse DNS on MX, started off the connection thread once the client has waited for the
  banner, in `Received:` and the envelope, with no more lookups at once than `max_connections`; the envelope's
  `reverse_dns_status` tells a DNS failure from a client with no name, and `unconfirmed_hostname` keeps a PTR
  name that does not resolve back, for negative checks only
- a banner held back on MX, refusing a client that talks first
- an error tarpit: a pause before each error reply past a soft limit, a 421 at the hard limit
- every option but the backend has a default
- an optional scorer, called once after DATA, with one verdict for every recipient
- a queue id for each message, in the envelope and on its log lines
- an optional instrument hook, with plain data for metrics

Plus:

- a backend interface, so mailgate never sees your accounts or database
- the backend chooses what happens to mail the scorer could not score
- TLS reloaded from the backend without a restart



## Contents

- [Installation](#installation)
- [Getting Started](#getting-started)
- [Design](#design)
- [Interfaces](#interfaces)
- [Options](#options)
- [Testing](#testing)
- [History](#history)
- [Contributing](#contributing)
- [License](#license)



## Installation

```ruby
gem "mailgate", github: "mailpiece/mailgate"
```

Requires Ruby >= 3.4. Builds on mailsmtp's `before_banner` hook and observers.

## Getting Started

Write a [backend](docs/backend.md), then start a listener with it:

```ruby
require "mailgate"

MailGate::MxListener.new(backend: MxBackend.new).start
```

Every [option](#options) can be overridden, such as `hostname: "mx.example.com"`.



## Design

mailgate is the SMTP policy between [mailsmtp](https://github.com/mailpiece/mailsmtp) and your application. It
never stores, delivers or scores mail itself.

mailgate speaks SMTP only: it accepts mail (MX) and takes mail to send (submission). For mailboxes, pair it
with an IMAP server and deliver to it from `store`, for example over LMTP. Submission auth
hands the username and password to the backend.

- MX routes each recipient at RCPT TO through the backend, and hands each route back with its copy of the
  message after DATA. The 250 goes out once every recipient is stored.
- Submission requires STARTTLS and AUTH. The backend authenticates the username and password and takes the
  message; parsing and rewriting it are the backend's.
- An error the backend raises as a `MailSmtp::Error` is the reply. Any other error is a 451, and is reported
  to the backend.
- PROXY protocol v1 is in mailsmtp (`proxy_hosts`), but mailgate does not pass it through yet. mailsmtp reads
  the header before `connected`, so passing it through would give reverse DNS, the greet wait and the per-IP
  limits the client's address.

## Interfaces

- [Backend](docs/backend.md): what your application answers for each listener.
- [Scorer](docs/scorer.md): one verdict per message after DATA, such as from
  [mailscore](https://github.com/mailpiece/mailscore).
- [Instrument](docs/instrument.md): an event for each step worth counting, with plain data.

## Options

Only `backend` is required. `nil` turns off the ones mailsmtp lets you turn off.

| Option | MX | Submission | |
|---|---|---|---|
| `backend` | required | required | the [backend](docs/backend.md) |
| `hostname` | `Socket.gethostname` | `Socket.gethostname` | the banner, the greeting and the `Received:` stamp. The default is the machine's name, which in a container is its id, so set it to the name the MX record points at |
| `host` | `"0.0.0.0"` | `"0.0.0.0"` | where to listen; every interface |
| `port` | 25 | 587 | |
| `max_message_size` | 10240000 | 10240000 | bytes, advertised as SIZE |
| `max_recipients` | 1000 | 100 | per message; MX's is high so mail to many local recipients arrives in one transaction, and submission keeps mailsmtp's lower cap, so a leaked token reaches fewer people |
| `max_connections` | 100 | 100 | open connections, and on MX reverse DNS lookups at once, past which a client is `unknown` |
| `max_connections_per_ip` | 10 | 50 | open connections from one client, an IPv6 client counted by its /64, enforced by mailsmtp; MX's is a fifth of submission's, as nothing in front turns a flood away first |
| `max_processings` | 10 | 10 | messages read at once; ten bodies in memory stay near 100 MB |
| `max_processings_per_ip` | half of `max_processings` | half of `max_processings` | messages read at once from one client, an IPv6 client counted by its /64, at least 1; past it, mailsmtp answers DATA with a 451. Half, so one client holds at most half the slots |
| `max_messages_per_ip` | `nil` | — | per minute; off |
| `max_tls_sessions_per_ip` | `nil` | 20 | per minute; off on MX, and on for submission, where a person sends far fewer |
| `max_auth_attempts_per_ip` | — | 20 | per minute; on, as a person signs in far less often |
| `stress_threshold` | 1.0 | 1.0 | share of `max_connections` past which limits tighten; 1.0 is when every connection slot is taken |
| `scorer` | `nil` | — | optional |
| `scan_budget` | 8 | — | seconds the session waits for the scorer, mailscore's own; used only with a scorer |
| `read_timeout` | 30 | 30 | seconds idle before the connection drops |
| `max_processings_wait` | 30 | 30 | seconds a connection waits for a free `max_processings` slot before a 421 |
| `max_session_duration` | 300 | 300 | seconds a connection may last, and so the longest a body trickled in just above mailsmtp's minimum data rate holds a processing slot |
| `pending_input_limit` | 65536 | 65536 | bytes buffered ahead of a reply |
| `max_junk_commands` | 100 | 100 | NOOP, RSET, VRFY and repeated HELO or EHLO per connection, 1 under stress; past it, mailsmtp still answers each and counts it toward `hard_error_limit` |
| `greet_wait` | 6 | `nil` | seconds the banner waits, 2 under stress; a client that talks first gets a 554; `nil` turns it off |
| `error_sleep_time` | 1 | 1 | seconds slept before each error reply past `soft_error_limit` |
| `soft_error_limit` | 10 | 10 | 4xx and 5xx replies per connection before the sleep starts |
| `hard_error_limit` | 20 | 20 | replies per connection before a 421 and a hang-up, 1 under stress |
| `reverse_dns_timeout` | 5 | — | seconds from the banner the reverse DNS lookup may take before the client is `unknown`; each query gets mailresolver's timeouts cut to what is left |
| `resolver` | `nil` | — | for reverse DNS, such as a fake zone in tests; `nil` is [mailresolver](https://github.com/mailpiece/mailresolver); used as it is, so it must answer within `reverse_dns_timeout` |
| `instrument` | `nil` | `nil` | a callable for [events](docs/instrument.md), as `instrument.call(event, **data)` |
| `logger`, `logger_severity` | `nil` | `nil` | `nil` is mailsmtp's; as mailsmtp takes them |



## Testing

```sh
bundle install
rake
```



## History

View the [changelog](CHANGELOG.md).

## Contributing

Everyone is encouraged to help improve this project:

- [Report bugs](https://github.com/mailpiece/mailgate/issues)
- Fix bugs and submit pull requests
- Write, clarify, or fix documentation
- Suggest or add new features



## License

MIT. See [LICENSE](LICENSE).
