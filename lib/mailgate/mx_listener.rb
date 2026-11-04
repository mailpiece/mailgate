require "digest"

module MailGate
  class MxListener < Listener
    DEFAULTS = Listener::DEFAULTS.merge(
      port: 25,
      # A fifth of submission's, as nothing in front turns a flood away first.
      max_connections_per_ip: 10,
      # High, so mail to many local recipients arrives in one transaction.
      max_recipients: 1000,
      max_messages_per_ip: nil,
      # Long enough that a client that talks first shows itself.
      greet_wait: 6,
      scorer: nil,
      # mailscore's own.
      scan_budget: 8
    ).freeze

    def initialize(backend:, hostname: Socket.gethostname, host: DEFAULTS[:host], port: DEFAULTS[:port],
      max_message_size: DEFAULTS[:max_message_size], max_recipients: DEFAULTS[:max_recipients],
      max_processings: DEFAULTS[:max_processings], max_processings_per_ip: half_of(max_processings),
      max_connections: DEFAULTS[:max_connections],
      max_connections_per_ip: DEFAULTS[:max_connections_per_ip], max_messages_per_ip: DEFAULTS[:max_messages_per_ip],
      max_tls_sessions_per_ip: DEFAULTS[:max_tls_sessions_per_ip],
      stress_threshold: DEFAULTS[:stress_threshold], read_timeout: DEFAULTS[:read_timeout],
      max_processings_wait: DEFAULTS[:max_processings_wait], max_session_duration: DEFAULTS[:max_session_duration],
      pending_input_limit: DEFAULTS[:pending_input_limit], max_junk_commands: DEFAULTS[:max_junk_commands],
      resolver: DEFAULTS[:resolver], reverse_dns_timeout: DEFAULTS[:reverse_dns_timeout], greet_wait: DEFAULTS[:greet_wait],
      error_sleep_time: DEFAULTS[:error_sleep_time], soft_error_limit: DEFAULTS[:soft_error_limit],
      hard_error_limit: DEFAULTS[:hard_error_limit], scorer: DEFAULTS[:scorer], scan_budget: DEFAULTS[:scan_budget],
      instrument: DEFAULTS[:instrument], logger: DEFAULTS[:logger], logger_severity: DEFAULTS[:logger_severity])
      raise ConfigurationError, "scan_budget is required with a scorer" if scorer && scan_budget.nil?

      @scorer = scorer
      @scan_budget = scan_budget

      super(backend:, hostname:, host:, port:, max_message_size:, max_recipients:, max_processings:, max_processings_per_ip:,
        max_connections:, max_connections_per_ip:, max_messages_per_ip:, max_tls_sessions_per_ip:, stress_threshold:,
        read_timeout:, max_processings_wait:, max_session_duration:, pending_input_limit:, max_junk_commands:, resolver:, reverse_dns_timeout:, greet_wait:,
        error_sleep_time:, soft_error_limit:, hard_error_limit:, instrument:,
        logger:, logger_severity:,
        auth: :disabled,
        starttls: :optional,
        # Tolerate missing angle brackets: a 501 is permanent and costs mail from old senders.
        # Content is still held to the mailbox grammar; submission stays strict.
        strict_path: false,
        # Safe: inbound is stored, never relayed onward, so no 7-bit downgrade debt.
        eight_bit_mime: true)
    end

    def mail_from(session, address)
      with_queue_id(session) do
        raise Errors::StorageFull, "Storage limit reached, try again later" if backend.storage_full?

        sender_in(address)
      end
    end

    def rcpt_to(session, address)
      limit_recipients(session)

      # Domainless <Postmaster> (RFC 5321 §4.5.1) is unroutable; reject before recipient_in calls it syntax.
      raise Errors::RelayDenied, "Relay access denied for #{address}" if address.casecmp?("postmaster")

      address = recipient_in(address)

      # A repeat is accepted, as it costs the sender nothing to send it again, but it is neither routed nor stored twice.
      if session.routes.key?(mailbox = mailbox_of(address))
        address
      elsif route = backend.route(address)
        session.routes[mailbox] = [ address, route ]
        address
      else
        raise Errors::RelayDenied, "Relay access denied for #{address}"
      end
    end

    def receive(session, io)
      body = body_after_a_leading_fold(io.read)
      raise Errors::LoopDetected, "Loop detected" if looping?(body)

      raw = received_header(session) + AuthenticationResults.strip(body)
      digest = content_digest(session, body)
      envelope = envelope_of(session)
      verdict = score(raw, envelope)

      session.routes.values.uniq { |_, route| route }.each do |rcpt_to, route|
        backend.store(route, rcpt_to:, raw:, digest:, envelope:, verdict:)
      end

      log_accepted(session, body.bytesize)
    end

    private
      # The domain is case-insensitive (RFC 5321 §2.4); the local part is the receiving domain's to judge.
      def mailbox_of(address)
        local_part, _, domain = address.rpartition("@")
        "#{local_part}@#{domain.downcase}"
      end

      def recipients_of(session)
        session.routes.values.map(&:first)
      end

      def score(raw, envelope)
        if @scorer && verdict = check(raw, envelope)
          case verdict.action
          when :soft_reject then raise Errors::SoftRejected.new("Scored soft reject", reply: scored_reply(verdict, "4"))
          when :reject then raise Errors::Rejected.new("Scored reject", reply: scored_reply(verdict, "5"))
          else verdict
          end
        end
      end

      # Only a reply of the action's class, on one line of printable ASCII, so a verdict can't inject or accept.
      def scored_reply(verdict, reply_class)
        if verdict.respond_to?(:smtp_reply) && reply = verdict.smtp_reply
          code, enhanced, text = reply.code.to_s, reply.enhanced.to_s, reply.text.to_s

          if code.match?(/\A#{reply_class}\d\d\z/) && enhanced.match?(/\A#{reply_class}\.\d{1,3}\.\d{1,3}\z/) &&
              text.match?(/\A[ -~]{1,200}\z/)
            "#{code} #{enhanced} #{text}"
          end
        end
      end

      # The backend's unscored either refuses the message by raising or lets it through with no verdict.
      def check(raw, envelope)
        started = monotonic_time if @instrument
        verdict = @scorer.check(raw, envelope, budget: @scan_budget)
      rescue StandardError => error
        instrument(:scorer_failed, ip: envelope.ip, queue_id: envelope.queue_id, error: error.class.name,
          duration: monotonic_time - started) if @instrument
        backend.unscored(error, envelope)
        nil
      else
        instrument(:scorer_finished, ip: envelope.ip, queue_id: envelope.queue_id, action: verdict&.action,
          score: (verdict.score if verdict.respond_to?(:score)), duration: monotonic_time - started) if @instrument
        verdict
      end

      # The forward-confirmed name, or "unknown" as RFC 5321 §4.4 allows.
      def received_header(session)
        "Received: from #{host(session.helo)} (#{host(client_hostname(session))} [#{ip(session.remote_ip)}]) " \
          "by #{hostname} with #{session.encrypted? ? "ESMTPS" : "ESMTP"}; #{received_at}\r\n"
      end

      def host(value)
        value = value.to_s
        value.length.between?(1, 255) && value.match?(/\A[A-Za-z0-9.\-\[\]:_]+\z/) ? value : "unknown"
      end

      def ip(value)
        value = value.to_s
        value.length.between?(1, 64) && value.match?(/\A[0-9A-Fa-f.:]+\z/) ? value : "unknown"
      end

      def looping?(body)
        own_stamp = /\AReceived:.*\bby #{Regexp.escape(hostname)}\b/im
        HeaderSection.new(body).unfolded_fields.count { |field| field.match?(own_stamp) } > 4
      end

      def content_digest(session, body)
        Digest::SHA256.new.update("#{session.envelope.from}\n").update(body).hexdigest
      end
  end
end
