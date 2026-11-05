require "openssl"
require "securerandom"

module MailGate
  class Listener < MailSmtp::Server
    PENDING_INPUT_LIMIT = 64 * 1024
    QUEUE_ID_CHARS = [ *"A".."Z", *"0".."9" ].freeze
    LOGGED_RECIPIENTS = 10
    # The longest a banner is held back under stress.
    STRESS_GREET_WAIT = 2

    # What the constructors default each option to, where both listeners agree.
    DEFAULTS = {
      host: "0.0.0.0",
      max_message_size: 10_240_000,
      max_connections: 100,
      max_connections_per_ip: 50,
      # Each message read holds its body in memory, so ten at once bounds that near 100 MB.
      max_processings: 10,
      max_tls_sessions_per_ip: nil,
      # Limits tighten once every connection slot is taken.
      stress_threshold: 1.0,
      read_timeout: 30,
      max_processings_wait: 30,
      # A body trickled just above mailsmtp's minimum rate holds its processing slot until this ends the session.
      max_session_duration: 300,
      pending_input_limit: PENDING_INPUT_LIMIT,
      max_junk_commands: 100,
      greet_wait: nil,
      # A pause before each error reply past the soft limit, a 421 at the hard limit; the engine drops to one error under stress.
      error_sleep_time: 1,
      soft_error_limit: 10,
      hard_error_limit: 20,
      instrument: nil,
      logger: nil,
      logger_severity: nil
    }.freeze

    MAILBOX = %r{\A(?<local_part>[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*)@(?<domain>[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*)\z}

    # RFC 5321 §4.5.3.1.2
    MAX_DOMAIN_LENGTH = 255

    REMOTE_FAULTS = [ OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT, EOFError ].freeze

    attr_reader :backend, :hostname

    # The engine refuses a recipient cap under 100 (RFC 5321 §4.5.3.1), so a lower one is held in rcpt_to.
    def initialize(backend:, hostname:, max_recipients:, read_timeout: DEFAULTS[:read_timeout],
      max_processings_wait: DEFAULTS[:max_processings_wait], max_session_duration: DEFAULTS[:max_session_duration],
      pending_input_limit: DEFAULTS[:pending_input_limit], max_junk_commands: DEFAULTS[:max_junk_commands],
      resolver: nil, reverse_dns_timeout: nil, greet_wait: DEFAULTS[:greet_wait],
      error_sleep_time: DEFAULTS[:error_sleep_time], soft_error_limit: DEFAULTS[:soft_error_limit],
      hard_error_limit: DEFAULTS[:hard_error_limit], instrument: DEFAULTS[:instrument], **options)
      @backend = backend
      @instrument = instrument
      @hostname = hostname
      @recipient_limit = max_recipients
      @resolver = resolver
      @reverse_dns_timeout = reverse_dns_timeout
      @greet_wait = greet_wait

      super(tls: backend.tls, max_recipients: [ max_recipients, MAX_RECIPIENTS ].max,
        read_timeout:, max_processings_wait:, max_session_duration:, pending_input_limit:, max_junk_commands:,
        error_sleep_time:, error_sleep_after: soft_error_limit, max_exceptions: hard_error_limit,
        **options)

      # A lookup can outlive its connection by up to reverse_dns_timeout, so a client that connects and leaves in a loop
      # would otherwise spawn threads without bound.
      @reverse_dns_lookups = Slots.new(max_connections)
    end

    def reload_tls
      self.tls = backend.tls
    end

    def connected(session)
      session.banner = "#{hostname} ESMTP"
      session.greeting = hostname
      instrument(:connection_accepted, ip: session.remote_ip) if @instrument
    end

    # A client that talks before the banner never waited for it, as a real MTA does. Reverse DNS starts only once the
    # client has waited, so one that talks first or leaves costs no lookup. Only MX has a timeout and looks one up, as
    # submission's Received: never names the client.
    def before_banner(session, io)
      wait_for_greeting(session, io) if @greet_wait
      look_up_reverse_dns(session) if @reverse_dns_timeout && session.remote_ip
    end

    def disconnected(session)
      session.reverse_dns&.cancel
    end

    def build_session
      Session.new
    end

    def process_line(session, line)
      super
    rescue MailSmtp::AuthenticationFailed
      instrument(:auth_failed, ip: session.remote_ip) if @instrument
      raise
    rescue MailSmtp::RateLimited, MailSmtp::TooManyProcessings, MailSmtp::TlsUnavailable, MailSmtp::AuthenticationTemporarilyUnavailable => error
      instrument(:rate_limited, ip: session.remote_ip, limit: rate_limit_of(error)) if @instrument
      raise
    end

    # mailsmtp's observers. A refusal at max_connections comes from its acceptor thread, before there is a session.
    def connection_refused(remote_ip, limit)
      instrument(:connection_refused, ip: remote_ip, limit:) if @instrument
    end

    def error_slept(session, seconds)
      instrument(:error_tarpitted, ip: session.remote_ip, duration: seconds) if @instrument
    end

    def error_limit_reached(session)
      instrument(:error_limit_reached, ip: session.remote_ip) if @instrument
    end

    # Also for a reply to a client refused before connected ran.
    def replied(session, code)
      instrument(:replied, ip: session.remote_ip, code:) if @instrument
    end

    def log(session, severity, msg, err: nil)
      msg = "[#{session.queue_id}] #{msg}" if session.respond_to?(:queue_id) && session.queue_id
      super(session, severity, msg, err:)

      backend.report_error(err) if err && reportable?(severity, err)
    end

    private
      # The default max_processings_per_ip: one client holds at most half the slots, 5 of 10.
      def half_of(max_processings)
        [ max_processings / 2, 1 ].max
      end

      # The application's hook never touches the session.
      def instrument(event, **data)
        raise ArgumentError, "#{event.inspect} is not in MailGate::EVENTS" unless EVENTS.include?(event)

        begin
          @instrument.call(event, **data)
        rescue StandardError => error
          backend.report_error(error)
        end
      end

      def wait_for_greeting(session, io)
        deadline = monotonic_time + (stressed? ? [ @greet_wait, STRESS_GREET_WAIT ].min : @greet_wait)

        while (remaining = deadline - monotonic_time) > 0
          next unless IO.select([ io ], nil, nil, remaining)

          case io.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
          when :wait_readable then next
          when nil, "" then raise EOFError
          else
            # Read what it sent, or closing on unread bytes resets the connection before it sees the 554.
            io.read_nonblock(PENDING_INPUT_LIMIT, exception: false)
            instrument(:pregreet_refused, ip: session.remote_ip) if @instrument
            raise Errors::EarlyTalker, "Client talked before the banner"
          end
        end
      end

      def look_up_reverse_dns(session)
        session.reverse_dns = ReverseDns.new(@resolver, session.remote_ip, timeout: @reverse_dns_timeout,
          slots: @reverse_dns_lookups)
      end

      # mailsmtp raises these only past its per-IP rates.
      def rate_limit_of(error)
        case error
        when MailSmtp::RateLimited then :messages_per_ip
        when MailSmtp::TooManyProcessings then :processings_per_ip
        when MailSmtp::TlsUnavailable then :tls_sessions_per_ip
        else :auth_attempts_per_ip
        end
      end

      def reportable?(severity, err)
        if err.is_a?(MailSmtp::Error) || shutdown? || REMOTE_FAULTS.any? { |fault| err.is_a?(fault) }
          false
        else
          severity == Logger::ERROR || severity == Logger::FATAL
        end
      end

      def limit_recipients(session)
        if session.envelope.to.size >= @recipient_limit
          raise MailSmtp::TooManyRecipients, "Too many recipients, maximum is #{@recipient_limit}"
        end
      end

      # Empty address is the null reverse-path <> used by bounces (RFC 5321 §4.5.5).
      def sender_in(address)
        raise MailSmtp::InvalidParameters, "Malformed sender address" unless address.empty? || mailbox?(address)

        address
      end

      def recipient_in(address)
        raise MailSmtp::InvalidParameters, "Malformed recipient address" unless mailbox?(address)

        address
      end

      def mailbox?(address)
        if mailbox = MAILBOX.match(address)
          mailbox[:domain].bytesize <= MAX_DOMAIN_LENGTH
        else
          false
        end
      end

      # An id only for an accepted MAIL FROM, kept until the next so the reply to DATA logs with it.
      def with_queue_id(session)
        session.queue_id = nil
        yield.tap { session.queue_id = SecureRandom.alphanumeric(12, chars: QUEUE_ID_CHARS) }
      end

      def envelope_of(session)
        Envelope.new(ip: session.remote_ip, hostname: client_hostname(session), helo: session.helo, mail_from: session.envelope.from,
          rcpt_to: recipients_of(session), tls_version: session.tls_version, tls_cipher: session.tls_cipher,
          queue_id: session.queue_id, reverse_dns_status: reverse_dns_status(session))
      end

      def recipients_of(session)
        session.envelope.to.dup
      end

      # Joined on first use, so the lookup has had since connect.
      def client_hostname(session)
        session.client_hostname ||= if session.reverse_dns
          session.reverse_dns.result.tap { |result| reverse_dns_finished(session, result) }.name
        else
          ReverseDns::UNKNOWN
        end
      end

      # Apart from the name, so a scorer can tell a lookup that failed from a client with no name. nil when not looked up,
      # busy included: a client holding every slot would otherwise make each one look like a DNS failure.
      def reverse_dns_status(session)
        case session.reverse_dns&.result&.outcome
        when nil, :busy then nil
        when :verified then "confirmed"
        when :unconfirmed then "unconfirmed"
        when :not_found then "none"
        else "temporary_failure"
        end
      end

      def reverse_dns_finished(session, result)
        log_reverse_dns(session, result)
        instrument(:reverse_dns_finished, ip: session.remote_ip, outcome: reverse_dns_outcome(result), duration: result.duration) if @instrument
      end

      def reverse_dns_outcome(result)
        case result.outcome
        when :verified then :verified
        when :not_found, :unconfirmed then :unknown
        else :temporary_failure
        end
      end

      def log_reverse_dns(session, result)
        case result.outcome
        when :unconfirmed
          log(session, Logger::INFO, "[smtp] Reverse DNS name does not resolve back to the client")
        when :temporary_failure
          log(session, Logger::WARN, "[smtp] Reverse DNS failed temporarily: #{result.error.message}")
        when :timeout
          log(session, Logger::WARN, "[smtp] Reverse DNS timed out after #{@reverse_dns_timeout}s")
        when :busy
          log(session, Logger::WARN, "[smtp] Reverse DNS skipped: #{max_connections} lookups already running")
        when :error
          log(session, Logger::ERROR, "[smtp] Reverse DNS failed: #{result.error.message}", err: result.error)
        end
      end

      # A first line opening with a space or tab would continue our Received: stamp, letting the client write the end of
      # it. As in Postfix, an empty line goes before it, so the whole message is body and has no header of its own.
      def body_after_a_leading_fold(body)
        body.start_with?(" ", "\t") ? "\r\n#{body}" : body
      end

      def received_at
        Time.now.utc.strftime("%a, %d %b %Y %H:%M:%S +0000")
      end

      def log_accepted(session, bytesize)
        recipients = recipients_of(session)

        log(session, Logger::INFO,
          "[smtp] #{self.class.name} accepted #{bytesize} bytes from #{envelope_from(session)} to #{logged(recipients)}")
        instrument(:message_accepted, ip: session.remote_ip, queue_id: session.queue_id, bytes: bytesize,
          recipients: recipients.size) if @instrument
      end

      # A thousand recipients would make one line of 50 KB.
      def logged(recipients)
        listed = recipients.first(LOGGED_RECIPIENTS).join(", ")
        recipients.size > LOGGED_RECIPIENTS ? "#{listed} and #{recipients.size - LOGGED_RECIPIENTS} more" : listed
      end

      def envelope_from(session)
        session.envelope.null_sender? ? "<>" : session.envelope.from
      end
  end
end
