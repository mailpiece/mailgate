require "digest"

module MailGate
  class SubmissionListener < Listener
    DEFAULTS = Listener::DEFAULTS.merge(
      port: 587,
      # mailsmtp's RFC 5321 minimum rather than MX's 1000: a leaked token reaches fewer people per message.
      max_recipients: 100,
      # Unlike MX, on: a client that guesses tokens or renegotiates TLS faster than a person sends mail is an attack.
      max_tls_sessions_per_ip: 20,
      max_auth_attempts_per_ip: 20
    ).freeze

    def initialize(backend:, hostname: Socket.gethostname, host: DEFAULTS[:host], port: DEFAULTS[:port],
      max_message_size: DEFAULTS[:max_message_size], max_recipients: DEFAULTS[:max_recipients],
      max_processings: DEFAULTS[:max_processings], max_processings_per_ip: half_of(max_processings),
      max_connections: DEFAULTS[:max_connections],
      max_connections_per_ip: DEFAULTS[:max_connections_per_ip], max_tls_sessions_per_ip: DEFAULTS[:max_tls_sessions_per_ip],
      max_auth_attempts_per_ip: DEFAULTS[:max_auth_attempts_per_ip],
      stress_threshold: DEFAULTS[:stress_threshold], read_timeout: DEFAULTS[:read_timeout],
      max_processings_wait: DEFAULTS[:max_processings_wait], max_session_duration: DEFAULTS[:max_session_duration],
      pending_input_limit: DEFAULTS[:pending_input_limit], max_junk_commands: DEFAULTS[:max_junk_commands],
      resolver: DEFAULTS[:resolver], reverse_dns_timeout: DEFAULTS[:reverse_dns_timeout], greet_wait: DEFAULTS[:greet_wait],
      error_sleep_time: DEFAULTS[:error_sleep_time], soft_error_limit: DEFAULTS[:soft_error_limit],
      hard_error_limit: DEFAULTS[:hard_error_limit], instrument: DEFAULTS[:instrument],
      logger: DEFAULTS[:logger], logger_severity: DEFAULTS[:logger_severity])
      super(backend:, hostname:, host:, port:, max_message_size:, max_recipients:, max_processings:, max_processings_per_ip:,
        max_connections:, max_connections_per_ip:, max_tls_sessions_per_ip:, max_auth_attempts_per_ip:, stress_threshold:,
        read_timeout:, max_processings_wait:, max_session_duration:, pending_input_limit:, max_junk_commands:, resolver:, reverse_dns_timeout:, greet_wait:,
        error_sleep_time:, soft_error_limit:, hard_error_limit:, instrument:,
        logger:, logger_severity:,
        auth: :required,
        starttls: :required,
        # Submitted mail is relayed onward, and we never downgrade it.
        eight_bit_mime: false)
    end

    def authenticate(session, username:, password:, **)
      if id = backend.authenticate(username, password, ip: session.remote_ip)
        id = granted_id(id)
        log(session, Logger::INFO, "[smtp] #{self.class.name} authenticated #{id} from #{session.remote_ip}")
        instrument(:auth_succeeded, ip: session.remote_ip) if @instrument
        id
      else
        # Don't echo the username: a mistyped token would land in ERROR logs.
        raise MailSmtp::AuthenticationFailed, "Authentication failed"
      end
    end

    # The account is checked before any body is read.
    def mail_from(session, address)
      with_queue_id(session) do
        address = sender_in(address)
        id = session.authorization_id

        raise Errors::AccountInactive, "Account is not active" unless backend.account_active?(id)
        if backend.rate_limited?(id)
          instrument(:rate_limited, ip: session.remote_ip, limit: :account) if @instrument
          raise Errors::RateLimited, "Rate limit exceeded, try again shortly"
        end

        if backend.may_send_as?(id, address)
          address
        else
          raise Errors::SenderNotAuthorized, "Not authorized to send as #{address}"
        end
      end
    end

    def rcpt_to(session, address)
      limit_recipients(session)
      recipient_in(address)
    end

    def receive(session, io)
      body = io.read
      refuse_a_leading_fold(body)

      backend.submit(session.authorization_id, raw: body, received: received_header(session), envelope: envelope_of(session), key: submission_key(session, body))

      log_accepted(session, body.bytesize)
    end

    private
      # The engine takes only a non-empty String or Symbol as the grant; anything else would leave the client's
      # username. Checked before it is logged, so a line break can't forge a log line.
      def granted_id(id)
        raise ConfigurationError, "authenticate returned a #{id.class}, not a String or Symbol" unless id.is_a?(String) || id.is_a?(Symbol)

        id.to_s.tap do |granted|
          raise ConfigurationError, "authenticate returned an empty id" if granted.empty?
          raise ConfigurationError, "authenticate returned an id with a line break" if granted.match?(/[\r\n]/)
        end
      end

      # Don't broadcast the client IP (ESP injection, not MX relay).
      def received_header(_session)
        "Received: by #{hostname} with ESMTPSA; #{received_at}\r\n"
      end

      # Scoped to the account, so one account's message can never be taken for another's resubmission.
      def submission_key(session, body)
        Digest::SHA256.new
          .update("#{session.authorization_id}\n#{session.envelope.from}\n#{session.envelope.to.sort.join(",")}\n")
          .update(body)
          .hexdigest
      end
  end
end
