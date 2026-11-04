# Backend

This page describes the backend, the application behind a listener that knows accounts, domains, tokens and
storage. For the verdict on a message, see [Scorer](scorer.md); for metrics, see [Instrument](instrument.md).

The code lives in [lib/mailgate/mx_listener.rb](../lib/mailgate/mx_listener.rb) and
[lib/mailgate/submission_listener.rb](../lib/mailgate/submission_listener.rb).

mailgate drives the SMTP phases and calls the backend; it never sees an account or a database.

```ruby
MailGate::MxListener.new(backend: MxBackend.new, ...)
MailGate::SubmissionListener.new(backend: SubmissionBackend.new, ...)
```

The listener holds one backend for its whole life, and calls it from many connection threads at once.

## Every call

- Takes everything it needs as arguments. The account comes from the recipient's route or the authorization
  id, never from thread state left by an earlier call.
- Runs in the application's own context. In Rails, wrap each call in `Rails.application.executor.wrap` and
  look up constants inside it, so a long-lived listener never holds classes the reloader has replaced.
- May raise a `MailSmtp::Error` to choose the reply. Any other error gets a 451, and is passed to
  `report_error`.

## Both listeners

### `tls → tls object`

The STARTTLS context, an object with `start(io)` as mailsmtp takes. Called at boot and by
`listener.reload_tls`. Raise to keep the listener from booting without a certificate.

### `report_error(error)`

An unexpected error from a hook or from the backend itself. Errors that are the client's fault (a TLS
handshake, a reset connection) and `MailSmtp::Error`s are not reported.

## MX

### `storage_full? → boolean`

At MAIL FROM. True refuses the transaction with a 452.

### `route(address) → route or nil`

At RCPT TO, once for each recipient. A repeated recipient, its domain in any case, gets a 250 without asking
again. `nil` refuses it with a 550. Any other value is the recipient's route, such as a mailbox, a bounce
address, a reserved address, a forward or a discard, and is handed back to `store` untouched.

Refuse a full mailbox for that recipient alone by raising your own `MailSmtp::Error` with a 452 from `route`,
such as `status 452, "Requested mail action not taken: mailbox full", enhanced: "4.2.2"`; the other recipients
are still accepted. `storage_full?` stays the check for the whole service.

### `store(route, rcpt_to:, raw:, digest:, envelope:, verdict:)`

After DATA, once for each distinct route, under the first recipient that had it. Return only once the message
is committed: the 250 goes out after every route is stored, and one failure answers the whole message with a
451, so a sender retries all of it.

Deduplicate on the route plus `digest`. A retry after a 451 stores again every route that had already
committed, and a sender can send the same message again on another connection.

- `raw` is the message as received, with mailgate's `Received:` on top and every `Authentication-Results` and
  `Received-SPF` removed. `ARC-Authentication-Results` is kept, as ARC verification needs each forwarder's
  sealed copy as it was sent. A message whose first line opens with a space or tab gets an empty line before it,
  as in Postfix, so it is all body rather than a continuation of the `Received:`.
- `digest` is a SHA-256 of the sender and the body, the same for a retry of the same message. Use it to store
  a retry once.
- `envelope` is a `MailGate::Envelope`: `ip`, `hostname`, `helo`, `mail_from`, `rcpt_to`, `tls_version`,
  `tls_cipher`, `queue_id`. `hostname` is the client's forward-confirmed reverse DNS name, or `unknown`.
  `queue_id` is a short id for the message, the same one mailgate's log lines carry.
- `verdict` is the [scorer](scorer.md)'s verdict, or `nil` when there is no scorer or the message went
  unscored. Marking or rewriting the subject on its action is up to the backend.

### `unscored(error, envelope)`

The scorer raised. Return to store the message with no verdict, perhaps scoring it later, or raise a
`MailSmtp::Error` to refuse it, such as `MailSmtp::LocalError` for a 451.

## Submission

`id` is what `authenticate` returned, as a String. At MAIL FROM, `account_active?`, `rate_limited?` and then
`may_send_as?` run before any content is read.

### `authenticate(username, password, ip:) → id or nil`

At AUTH, with the username and password the client sent over PLAIN or LOGIN. The backend decides what the pair
means: a mailbox login, or a token whose username it ignores. `nil` gets a 535. The id is a non-empty String
or Symbol without a line break; anything else is reported as a `MailGate::ConfigurationError`, and the client
gets a 451. Raise `MailGate::Errors::AddressNotAllowed` to refuse a good token from an address it may not use:
it is a `MailSmtp::AuthenticationFailed`, so refusals count toward the cap on failed attempts.

### `may_send_as?(id, address) → boolean`

At MAIL FROM. False gets a 550. Raise your own `MailSmtp::Error` for a more specific refusal, such as a domain
not yet verified.

### `account_active?(id) → boolean`

At MAIL FROM. False gets a 550.

### `rate_limited?(id) → boolean`

At MAIL FROM, once for each message. True gets a 452.

### `submit(id, raw:, received:, envelope:, key:)`

After DATA. Accept the message for sending and return once it is committed.

- `envelope` is a `MailGate::Envelope`, as `store` gets it, but with `hostname` always `unknown`: submission
  looks up no reverse DNS, as its `Received:` never names the client.
- `raw` is the message as submitted, with an empty line before a first line that opens with a space or tab, as
  `store` gets it. Check the identity headers (From, Sender) here as well as the envelope sender.
- `received` is mailgate's `Received:` line. Put it on top after removing the client's own `Received:`
  headers.
- `key` is a SHA-256 of the account's `id`, the envelope and the body. Use it so a resubmission of the same
  message is sent once; raise `MailGate::Errors::DuplicateSubmission` (451) while the first is still in
  progress. The key is coarse: a client that changes any byte, such as a fresh `Date` or `Message-ID`, is
  sending a new message.
- Raise `MailGate::Errors::InvalidMessage` (550) for a message the sender must fix. Anything else gets a 451.
