require "mailsmtp"

require "mailgate/version"
require "mailgate/errors"
require "mailgate/slots"
require "mailgate/header_section"
require "mailgate/authentication_results"
require "mailgate/envelope"
require "mailgate/reverse_dns"
require "mailgate/session"
require "mailgate/listener"
require "mailgate/mx_listener"
require "mailgate/submission_listener"

# MX and submission listeners on top of mailsmtp.
module MailGate
  # Every event the instrument hook is sent, as docs/instrument.md lists them.
  EVENTS = %i[
    connection_accepted pregreet_refused reverse_dns_finished scorer_finished scorer_failed message_accepted
    auth_succeeded auth_failed rate_limited connection_refused error_tarpitted error_limit_reached replied
  ].freeze
end
