module MailGate
  # Only our own verdicts may claim to be ours, so every inbound one goes. ARC-Authentication-Results stays: it is
  # sealed by the forwarder that wrote it, and ARC verification needs it as sent.
  class AuthenticationResults
    FIELD = /\A(?:Authentication-Results|Received-SPF)\s*:/i

    def self.strip(message)
      HeaderSection.new(message).without(FIELD)
    end
  end
end
