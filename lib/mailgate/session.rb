module MailGate
  class Session < MailSmtp::Session
    attr_accessor :reverse_dns, :client_hostname, :queue_id
    attr_reader :routes

    # mailsmtp resets the session once a body is read and drained, whichever way DATA ended.
    def reset
      super
      @routes = {}
    end
  end
end
