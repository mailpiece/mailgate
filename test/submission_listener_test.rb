require "test_helper"

class MailGate::SubmissionListenerTest < MailGate::ListenerTestCase
  TOKEN = "secret-token"
  MESSAGE = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Hi\r\n\r\nBody.\r\n"

  # Checks the identity headers and restamps the message inside submit, as an application's would.
  class IdentityCheckingBackend < MailGate::FakeBackend
    def submit(id, raw:, received:, **message)
      headers, body = raw.split("\r\n\r\n", 2)
      headers = headers.split("\r\n")

      headers.grep(/\A(?:from|sender):/i).each do |header|
        address = header.split(":", 2).last.strip
        raise MailGate::Errors::SenderNotAuthorized, "Not authorized to send as #{address}" unless may_send_as?(id, address)
      end

      super(id, raw:, received:, sent: received + headers.grep_v(/\Areceived:/i).join("\r\n") + "\r\n\r\n" + body, **message)
    end
  end

  def setup
    @backend = MailGate::FakeBackend.new
    @backend.tokens = { TOKEN => "token-1" }
    @backend.senders = { "token-1" => [ "sender@example.com" ] }
    start_listener
  end

  def test_passes_max_processings_wait_to_the_engine
    assert_equal 30, @listener.instance_variable_get(:@max_processings_wait)

    restart_listener(max_processings_wait: 5)

    assert_equal 5, @listener.instance_variable_get(:@max_processings_wait)
  end

  def test_defaults_every_option_but_the_backend
    listener = MailGate::SubmissionListener.new(backend: @backend)

    assert_equal Socket.gethostname, listener.hostname
    assert_equal [ [ "0.0.0.0", 587 ] ], listener.instance_variable_get(:@addresses)
    assert_equal 10_240_000, listener.max_message_size
    assert_equal 100, listener.max_recipients
    assert_equal 10, listener.max_processings
    assert_equal 5, listener.instance_variable_get(:@max_processings_per_ip)
    assert_equal 100, listener.max_connections
    assert_equal 50, listener.max_connections_per_ip
    assert_equal 20, listener.instance_variable_get(:@max_tls_sessions_per_ip)
    assert_equal 20, listener.instance_variable_get(:@max_auth_attempts_per_ip)
    assert_equal 1.0, listener.instance_variable_get(:@stress_threshold)
  end

  def test_overrides_each_default
    listener = MailGate::SubmissionListener.new(backend: @backend, hostname: "submission.example", host: "127.0.0.1",
      port: 2587, max_message_size: 5_000, max_recipients: 50, max_processings: 3, max_connections: 20,
      max_connections_per_ip: 4, max_tls_sessions_per_ip: 60, max_auth_attempts_per_ip: 10, stress_threshold: 0.8)

    assert_equal "submission.example", listener.hostname
    assert_equal [ [ "127.0.0.1", 2587 ] ], listener.instance_variable_get(:@addresses)
    assert_equal 5_000, listener.max_message_size
    assert_equal 50, listener.instance_variable_get(:@recipient_limit)
    assert_equal 3, listener.max_processings
    assert_equal 1, listener.instance_variable_get(:@max_processings_per_ip)
    assert_equal 20, listener.max_connections
    assert_equal 4, listener.max_connections_per_ip
    assert_equal 60, listener.instance_variable_get(:@max_tls_sessions_per_ip)
    assert_equal 10, listener.instance_variable_get(:@max_auth_attempts_per_ip)
    assert_equal 0.8, listener.instance_variable_get(:@stress_threshold)
  end

  def test_takes_max_processings_per_ip_over_half_of_max_processings
    assert_equal 4, MailGate::SubmissionListener.new(backend: @backend, max_processings_per_ip: 4).instance_variable_get(:@max_processings_per_ip)
    assert_nil MailGate::SubmissionListener.new(backend: @backend, max_processings_per_ip: nil).instance_variable_get(:@max_processings_per_ip)
  end

  def test_submits_under_the_id_the_backend_authenticated
    deliver

    submitted = @backend.submitted.first
    assert_equal "token-1", submitted[:id]
    assert_equal MESSAGE, submitted[:raw]
    assert_equal "sender@example.com", submitted[:envelope].mail_from
    assert_equal [ "recipient@example.com" ], submitted[:envelope].rcpt_to
    assert_match(/\A[A-Z0-9]{12}\z/, submitted[:envelope].queue_id)
  end

  def test_hands_over_a_received_by_line_without_the_clients_helo_or_ip
    deliver

    received = @backend.submitted.first[:received]
    assert_match(/\AReceived: by submission\.test with ESMTPSA; .* \+0000\r\n\z/, received)
    refute_includes received, "127.0.0.1"
  end

  def test_looks_up_no_reverse_dns_and_hands_the_backend_an_unknown_client
    assert_raises(ArgumentError) { MailGate::SubmissionListener.new(backend: @backend, resolver: Object.new) }

    deliver

    assert_equal "unknown", sole(@backend.submitted)[:envelope].hostname
    assert_nil sole(@backend.submitted)[:envelope].reverse_dns_status
    assert_nil sole(@backend.submitted)[:envelope].unconfirmed_hostname
    assert_nil @listener.instance_variable_get(:@reverse_dns_timeout)
  end

  def test_gives_a_resubmission_the_same_key_and_another_envelope_another
    2.times { deliver }
    deliver(to: "other@example.com")

    keys = @backend.submitted.map { |submitted| submitted[:key] }
    assert_equal keys[0], keys[1]
    refute_equal keys[0], keys[2]
  end

  def test_gives_the_same_message_from_another_account_another_key
    @backend.tokens = { TOKEN => "token-1", "other-token" => "token-2" }
    @backend.senders = { "token-1" => [ "sender@example.com" ], "token-2" => [ "sender@example.com" ] }

    deliver
    deliver(token: "other-token")

    assert_equal %w[ token-1 token-2 ], @backend.submitted.map { |submitted| submitted[:id] }
    refute_equal(*@backend.submitted.map { |submitted| submitted[:key] })
  end

  def test_hands_back_a_symbol_id_as_a_string_never_as_the_username
    @backend.tokens = { TOKEN => :"token-42" }
    @backend.senders = { "token-42" => [ "sender@example.com" ] }

    deliver(username: "token-1")

    assert_equal [ :may_send_as?, "token-42", "sender@example.com" ], @backend.calls.assoc(:may_send_as?)
    assert_equal "token-42", @backend.submitted.first[:id]
  end

  def test_refuses_an_id_that_is_not_a_string_or_symbol_or_carries_a_line_break_before_logging_it
    log = StringIO.new
    restart_listener(logger: Logger.new(log))

    [ 42, Object.new, "token-1\r\nforged: line", "token-1\nforged: line" ].each do |id|
      @backend.tokens = { TOKEN => id }

      assert_raises(Net::SMTPAuthenticationError) { deliver }
    end

    assert_equal [ MailGate::ConfigurationError ] * 4, @backend.errors.map(&:class)
    refute_match(/^forged/, log.string)
    refute_match(/authenticated/, log.string)
  end

  def test_a_backends_own_refusal_reaches_the_client_unchanged
    domain_not_verified = Class.new(MailSmtp::Error) { status 553, "Domain not verified", enhanced: "5.7.26" }
    sending_disabled = Class.new(MailSmtp::Error) { status 554, "Sending is off", enhanced: "5.7.27" }

    @backend.fail_at :may_send_as?, domain_not_verified.new("publish its DKIM TXT")
    error = assert_raises(Net::SMTPFatalError) { deliver }
    assert_equal "553 5.7.26 Domain not verified", error.message.chomp

    @backend.fail_at :submit, sending_disabled.new("turned off in its settings")
    error = assert_raises(Net::SMTPFatalError) { deliver }
    assert_equal "554 5.7.27 Sending is off", error.message.chomp

    assert_empty @backend.errors
  end

  def test_submit_gets_what_a_backend_needs_to_check_identities_and_restamp_the_message
    @backend = IdentityCheckingBackend.new.tap { |backend| backend.tokens, backend.senders = @backend.tokens, @backend.senders }
    restart_listener
    message = "Received: from client.lan\r\nX-Tags: welcome\r\n#{MESSAGE}"

    deliver(message:)
    error = assert_raises(Net::SMTPFatalError) { deliver(message: message.sub("From: sender@", "From: ceo@")) }

    assert_equal "550 5.7.1 Requested action not taken: mailbox unavailable", error.message.chomp
    submitted = sole(@backend.submitted)
    assert_equal message, submitted[:raw]
    assert_match(/\AReceived: by submission\.test with ESMTPSA; [^\r\n]+\r\nX-Tags: welcome\r\nFrom:/, submitted[:sent])
    assert_equal [ "sender@example.com", [ "recipient@example.com" ] ], submitted[:envelope].to_h.values_at(:mail_from, :rcpt_to)
    assert_match(/\A\h{64}\z/, submitted[:key])
  end

  def test_hands_the_backend_the_username_the_client_sent_with_plain_and_login
    deliver(username: "jane@example.com")
    deliver(username: "john@example.com", auth_type: :login)

    assert_equal [ [ :authenticate, "jane@example.com", TOKEN ], [ :authenticate, "john@example.com", TOKEN ] ],
      @backend.calls.select { |call| call.first == :authenticate }
    assert_equal 2, @backend.submitted.size
  end

  def test_authenticates_with_auth_login
    deliver(auth_type: :login)

    assert_equal 1, @backend.submitted.size
  end

  def test_refuses_an_unknown_token_with_a_535
    error = assert_raises(Net::SMTPAuthenticationError) { deliver(token: "wrong-token") }

    assert_match "535", error.message
    assert_empty @backend.submitted
  end

  def test_refuses_a_token_from_an_address_it_may_not_use_with_a_535_5_7_1
    @backend.fail_at :authenticate, MailGate::Errors::AddressNotAllowed.new("not from here")

    error = assert_raises(Net::SMTPAuthenticationError) { deliver }

    assert_match "535 5.7.1", error.message
    assert_empty @backend.errors
  end

  def test_counts_address_refusals_toward_the_failed_authentication_cap
    @backend.fail_at :authenticate, MailGate::Errors::AddressNotAllowed.new("not from here")

    with_encrypted_session do |ssl|
      (MailSmtp::Server::MAX_AUTH_FAILURES - 1).times do
        assert_match(/\A535/, command(ssl, "AUTH PLAIN #{credential}"))
      end

      assert_match(/\A535/, command(ssl, "AUTH PLAIN #{credential}"))
      assert_match(/\A421/, ssl.gets.to_s)
    end
  end

  def test_refuses_a_sender_the_token_may_not_send_as_with_a_550
    error = assert_raises(Net::SMTPFatalError) { deliver(from: "someone@else.example") }

    assert_match "550", error.message
    assert_empty @backend.submitted
  end

  def test_refuses_a_submission_from_an_inactive_account_with_a_550
    @backend.inactive = true

    error = assert_raises(Net::SMTPFatalError) { deliver }

    assert_match "550", error.message
    assert_empty @backend.submitted
  end

  def test_refuses_an_inactive_or_rate_limited_account_at_mail_from_before_reading_a_body
    with_authenticated_session do |ssl|
      @backend.inactive = true
      assert_match(/\A550 5\.7\.1 /, command(ssl, "MAIL FROM:<sender@example.com>"))
      refute @backend.calls.assoc(:may_send_as?)

      @backend.inactive = false
      @backend.rate_limited = true
      assert_match(/\A452 4\.7\.0 /, command(ssl, "MAIL FROM:<sender@example.com>"))
    end

    assert_empty @backend.submitted
  end

  def test_checks_the_sender_before_counting_the_message_toward_the_rate_limit
    with_authenticated_session do |ssl|
      assert_match(/\A550 5\.7\.1 /, command(ssl, "MAIL FROM:<someone@else.example>"))
      refute @backend.calls.assoc(:rate_limited?)

      assert_match(/\A250/, command(ssl, "MAIL FROM:<sender@example.com>"))
    end

    assert_equal %i[ account_active? may_send_as? account_active? may_send_as? rate_limited? ],
      @backend.calls.map(&:first).drop_while { |call| call != :account_active? }
  end

  def test_refuses_a_rate_limited_account_with_a_452
    @backend.rate_limited = true

    error = assert_raises(Net::SMTPServerBusy) { deliver }

    assert_match "452", error.message
    assert_empty @backend.submitted
  end

  def test_refuses_an_invalid_message_permanently
    @backend.fail_at :submit, MailGate::Errors::InvalidMessage.new("Tags is too long")

    error = assert_raises(Net::SMTPFatalError) { deliver }

    assert_match "550 5.6.0", error.message
    assert_empty @backend.errors
  end

  def test_refuses_a_header_section_past_its_cap_with_a_552
    restart_listener(max_message_size: 1_000_000)
    header_lines = "X-Pad: #{"p" * 990}\r\n" * 300

    with_authenticated_session do |ssl|
      [ "MAIL FROM:<sender@example.com>", "RCPT TO:<recipient@example.com>", "DATA" ].each { |line| command ssl, line }

      assert_match(/\A552 5\.3\.4 /, command(ssl, "#{header_lines}\r\nBody.\r\n."))
    end

    assert_empty @backend.submitted
  end

  def test_ends_the_header_section_before_a_first_line_that_would_fold_into_the_received
    message = "\tfrom trusted.example\r\n#{MESSAGE}"

    2.times { deliver(message:) }

    assert_equal [ "\r\n#{message}" ] * 2, @backend.submitted.map { |submitted| submitted[:raw] }
    assert_equal 1, @backend.submitted.map { |submitted| submitted[:key] }.uniq.size
  end

  def test_asks_the_sender_to_retry_on_any_other_error_and_reports_it
    @backend.fail_at :submit, RuntimeError.new("boom")

    error = assert_raises(Net::SMTPServerBusy) { deliver }

    assert_match "451", error.message
    assert_equal [ "boom" ], @backend.errors.map(&:message)
  end

  def test_refuses_an_empty_id_from_the_backend_and_reports_it
    @backend.tokens = { TOKEN => "" }

    assert_raises(Net::SMTPAuthenticationError) { deliver }
    assert_equal [ MailGate::ConfigurationError ], @backend.errors.map(&:class)
  end

  def test_reports_a_backend_error_during_auth
    @backend.fail_at :authenticate, RuntimeError.new("boom")

    assert_raises(Net::SMTPAuthenticationError) { deliver }
    assert_equal [ "boom" ], @backend.errors.map(&:message)
  end

  def test_refuses_recipients_past_the_cap_with_a_452
    restart_listener(max_recipients: 2)

    error = assert_raises(Net::SMTPServerBusy) { deliver(to: %w[ a@example.com b@example.com c@example.com ]) }

    assert_match "452", error.message
    assert_empty @backend.submitted
  end

  def test_requires_starttls_and_does_not_advertise_8bitmime
    connect do |socket|
      read_smtp_response(socket)
      socket.write "EHLO client.example\r\n"
      capabilities = read_smtp_lines(socket)

      assert_includes capabilities, "250-STARTTLS"
      refute_includes capabilities, "250-8BITMIME"
      assert_match(/\A530/, command(socket, "MAIL FROM:<sender@example.com>"))
    end
  end

  def test_refuses_a_bare_path_and_a_domainless_postmaster_with_a_501
    with_authenticated_session do |ssl|
      assert_match(/\A501/, command(ssl, "MAIL FROM:sender@example.com"))
      assert_match(/\A250/, command(ssl, "MAIL FROM:<sender@example.com>"))
      assert_match(/\A501/, command(ssl, "RCPT TO:<Postmaster>"))
      assert_match(/\A501/, command(ssl, "RCPT TO:<not an address@@x>"))
    end
  end

  def test_greets_with_its_own_hostname
    connect { |socket| assert_match(/\A220 submission\.test ESMTP/, socket.gets) }
  end

  private
    def start_listener(**overrides)
      start(MailGate::SubmissionListener, backend: @backend, hostname: "submission.test", max_message_size: 10_000,
        max_recipients: 50, max_processings: 2, max_connections: 10, max_connections_per_ip: 10,
        max_tls_sessions_per_ip: nil, max_auth_attempts_per_ip: nil, stress_threshold: nil, **overrides)
    end

    def deliver(from: "sender@example.com", to: "recipient@example.com", token: TOKEN, username: "smtp", auth_type: :plain, message: MESSAGE)
      smtp = Net::SMTP.new("127.0.0.1", @port)
      smtp.enable_starttls(insecure_tls_context)
      smtp.start do
        smtp.authenticate(username, token, auth_type)
        smtp.send_message(message, from, to)
      end
    end

    def sole(records)
      assert_equal 1, records.size
      records.first
    end

    def credential
      Base64.strict_encode64("\0smtp\0#{TOKEN}")
    end

    def with_encrypted_session
      connect do |socket|
        read_smtp_response(socket)
        socket.write "EHLO client.example\r\n"
        read_smtp_lines(socket)

        ssl = starttls(socket)
        ssl.write "EHLO client.example\r\n"
        read_smtp_lines(ssl)

        yield ssl
      end
    end

    def with_authenticated_session
      with_encrypted_session do |ssl|
        assert_match(/\A235/, command(ssl, "AUTH PLAIN #{credential}"))

        yield ssl
      end
    end
end
