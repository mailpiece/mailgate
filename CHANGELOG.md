# Changelog

## Unreleased

- First release: MX and submission listeners on mailsmtp, with a backend for storage and an optional scorer
- Refuse a header section over 256 KB on submission too
- Accept a message that starts with a folded line, as body, as Postfix does
- Look up no reverse DNS on submission
- Check the sender before the rate limit at MAIL FROM, so a refused sender costs no quota
- Refuse a rate-limited account with a 450 4.7.1, not a 452 for full storage
- Add `reverse_dns_status` to the envelope, telling a DNS failure from a client with no name
- Add `unconfirmed_hostname` to the envelope: a PTR name that does not resolve back, for negative checks only
