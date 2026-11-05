module MailGate
  # A listener or backend set up wrongly; an ArgumentError so a rescue written for the bare one still catches it.
  class ConfigurationError < ArgumentError; end

  # Policy replies; protocol errors come from MailSmtp::* in the engine.
  module Errors
    # A subclass so refusals count toward the engine's cap on failed AUTH attempts.
    class AddressNotAllowed < MailSmtp::AuthenticationFailed
      status 535, "Authentication not accepted from this address", enhanced: "5.7.1"
    end

    class DuplicateSubmission < MailSmtp::Error
      status 451, "Requested action aborted: local error in processing", enhanced: "4.3.0"
    end

    # MailSmtp::RateLimited's code and status in its own words; not that class, which the listener counts per IP.
    class RateLimited < MailSmtp::Error
      status 450, "Requested mail action not taken: too many messages, try again later", enhanced: "4.7.1"
    end

    class StorageFull < MailSmtp::Error
      status 452, "Requested action not taken: insufficient system storage", enhanced: "4.3.1"
    end

    class HeaderSectionTooLarge < MailSmtp::Error
      status 552, "Requested mail action aborted: exceeded storage allocation", enhanced: "5.3.4"
    end

    class RelayDenied < MailSmtp::Error
      status 550, "Requested action not taken: mailbox unavailable", enhanced: "5.7.1"
    end

    class SenderNotAuthorized < MailSmtp::Error
      status 550, "Requested action not taken: mailbox unavailable", enhanced: "5.7.1"
    end

    class AccountInactive < MailSmtp::Error
      status 550, "Requested action not taken: mailbox unavailable", enhanced: "5.7.1"
    end

    class InvalidMessage < MailSmtp::Error
      status 550, "Requested action not taken: mailbox unavailable", enhanced: "5.6.0"
    end

    # Answers with the scorer's reply when the listener found it well formed.
    module ScoredReply
      def initialize(message = nil, reply: nil)
        super(message)
        @reply = reply
      end

      def response
        @reply || super
      end
    end

    class SoftRejected < MailSmtp::Error
      include ScoredReply
      status 451, "Try again later", enhanced: "4.7.1"
    end

    class Rejected < MailSmtp::Error
      include ScoredReply
      status 554, "Spam message rejected", enhanced: "5.7.1"
    end

    # A ServiceUnavailable so the engine answers it and hangs up.
    class EarlyTalker < MailSmtp::ServiceUnavailable
      status 554, "Protocol error: talking before the greeting", enhanced: "5.7.1"
    end

    class LoopDetected < MailSmtp::Error
      status 554, "Transaction failed", enhanced: "5.4.6"
    end
  end
end
