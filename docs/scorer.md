# Scorer

This page describes the scorer, which judges a message the MX listener has received. For what happens to a
message it could not score, see [Backend](backend.md); for its timings, see [Instrument](instrument.md).

The code lives in [lib/mailgate/mx_listener.rb](../lib/mailgate/mx_listener.rb).

The scorer is optional; without one, every message is stored with no verdict.

```ruby
MailGate::MxListener.new(backend:, scorer: Scorer.new)
```

`scan_budget` is in seconds, 8 by default as mailscore's own. The SMTP session waits up to it after DATA.

## `check(raw, envelope, budget:) → verdict`

Called once a message, after DATA, before anything is stored. One verdict covers every recipient.

- `raw` is the message as it will be stored.
- `envelope` is a `MailGate::Envelope`: `ip`, `hostname`, `helo`, `mail_from`, `rcpt_to`, `tls_version`,
  `tls_cipher`, `queue_id`, `reverse_dns_status`, as the [backend](backend.md#storeroute-rcpt_to-raw-digest-envelope-verdict) gets it.
- `budget` is `scan_budget`.

The verdict responds to `action`, one of these:

| Action | mailgate does |
|---|---|
| `:no_action` | stores it |
| `:add_header` | stores it; the backend marks it |
| `:rewrite_subject` | stores it; the backend rewrites the subject |
| `:soft_reject` | its `smtp_reply`, or 451 4.7.1; nothing stored |
| `:reject` | its `smtp_reply`, or 554 5.7.1; nothing stored |

The verdict reaches the backend's `store` untouched, so it can carry a score, symbols or a new subject.

A refusing verdict may respond to `smtp_reply`, with `code`, `enhanced` and `text`. mailgate replies with it
only when `code` is 4xx for `:soft_reject` and 5xx for `:reject`, `enhanced` is `class.subject.detail` of the
same class, and `text` is 1 to 200 printable ASCII characters. Otherwise it gives its own reply above.

## Failure

Raise on any failure: a timeout, a refused connection, an error answer. mailgate passes the error to the
backend's `unscored`, which decides whether to accept the message unscored: returning fails open and stores it
with no verdict, raising fails closed and refuses it.

## Timeout

mailgate never interrupts `check`, so the scorer must enforce its own timeout, near `budget`. A call that
hangs holds the client's connection and a `max_processings` slot for as long as it hangs: no other deadline
reaches it.

## With mailscore

A scorer for [mailscore](https://github.com/mailpiece/mailscore) wraps `MailScore::Client`, whose errors
already raise. The client comes from its own gem:

```ruby
gem "mailscore-ruby", github: "mailpiece/mailscore-ruby"
```

```ruby
class Scorer
  def initialize(client)
    @client = client
  end

  def check(raw, envelope, budget:)
    @client.check(raw, ip: envelope.ip, helo: envelope.helo, hostname: envelope.hostname,
      from: envelope.mail_from, rcpt: envelope.rcpt_to,
      tls_version: envelope.tls_version, tls_cipher: envelope.tls_cipher, queue_id: envelope.queue_id)
  end
end
```

Give the client a read timeout above the budget mailscore is set to, so mailscore answers with a partial
verdict before the client gives up. `budget` is for a scorer that enforces it itself.
