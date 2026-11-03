require "test_helper"

class MailGate::ListenerTest < MailGate::ListenerTestCase
  def setup
    @backend = MailGate::FakeBackend.new
  end

  def test_greets_with_its_hostname
    start_listener

    connect { |socket| assert_equal "220 mx.test ESMTP\r\n", socket.gets }
  end

  def test_counts_junk_commands_past_its_cap_as_errors_until_the_hard_limit_drops_the_connection
    start_listener(max_junk_commands: 3, hard_error_limit: 2)

    connect do |socket|
      socket.gets

      4.times do
        socket.write("NOOP\r\n")
        assert_match(/\A250/, socket.gets.to_s)
      end

      socket.write("NOOP\r\n")
      assert_match(/\A421/, socket.gets.to_s)
      assert_nil socket.gets
    end
  end

  def test_drops_a_connection_on_its_second_junk_command_while_stressed
    start_listener
    @listener.define_singleton_method(:stressed?) { true }

    connect do |socket|
      socket.gets

      socket.write("NOOP\r\n")
      assert_match(/\A250/, socket.gets.to_s)

      socket.write("NOOP\r\n")
      assert_match(/\A421/, socket.gets.to_s)
      assert_nil socket.gets
    end
  end

  def test_counts_a_repeated_helo_or_ehlo_as_junk_but_not_the_one_after_starttls
    start_listener(max_junk_commands: 2, hard_error_limit: 1)

    connect do |socket|
      socket.gets
      socket.write("EHLO client.example\r\n")
      read_smtp_lines(socket)

      ssl = starttls(socket)
      [ "EHLO client.example", "HELO client.example", "EHLO client.example" ].each do |line|
        ssl.write("#{line}\r\n")
        assert_match(/\A250/, read_smtp_response(ssl).to_s, line)
      end

      ssl.write("EHLO client.example\r\n")
      assert_match(/\A421/, ssl.gets.to_s)
    end
  end

  def test_reload_tls_serves_the_backends_new_context_to_new_connections
    start_listener
    @backend.tls = MailGate::Tls::Context.new("renewed.example")

    refute_match(/renewed\.example/, peer_certificate.subject.to_s)
    @listener.reload_tls
    assert_match(/renewed\.example/, peer_certificate.subject.to_s)
  end

  def test_a_backend_without_a_certificate_keeps_the_listener_from_booting_and_a_failed_reload_keeps_the_old_one
    missing = Class.new(StandardError)
    @backend.tls = missing.new("no certificate yet")
    assert_raises(missing) { start_listener }

    @backend.tls = MailGate::Tls::TEST_CONTEXT
    start_listener
    @backend.tls = missing.new("renewal pending")
    assert_raises(missing) { @listener.reload_tls }
    assert_match(/mailgate\.test/, peer_certificate.subject.to_s)
  end

  def test_reports_a_genuine_error_but_not_a_reply_or_a_remote_fault
    listener = MailGate::Listener.allocate
    listener.instance_variable_set(:@backend, @backend)
    listener.instance_variable_set(:@stdout_logger, Logger.new(nil))

    [ MailSmtp::LocalError.new, OpenSSL::SSL::SSLError.new, Errno::ECONNRESET.new, EOFError.new ].each do |error|
      listener.log(nil, Logger::ERROR, "x", err: error)
    end
    boom = RuntimeError.new("boom")
    listener.log(nil, Logger::WARN, "x", err: boom)
    listener.log(nil, Logger::ERROR, "x", err: boom)

    assert_equal [ boom ], @backend.errors
  end

  def test_holds_addresses_to_the_rfc_5321_mailbox_grammar
    listener = MailGate::Listener.allocate

    assert listener.send(:mailbox?, "sender@example.com")
    assert listener.send(:mailbox?, "bounces+123.abc@mailer.example.com")
    assert listener.send(:mailbox?, "o'brien=news@single-label")

    [ "a b\"c@@x", ".leading@example.com", "double..dot@example.com", "user@-example.com", "user@example-.com",
      "user@example..com", "\"quoted string\"@example.com", "user@[127.0.0.1]", "user@", "@example.com" ].each do |address|
      assert_not_mailbox listener, address
    end
  end

  def test_enforces_the_rfc_5321_octet_ceiling_on_the_domain
    listener = MailGate::Listener.allocate
    longest_domain = Array.new(4) { "a" * 63 }.join(".")

    assert listener.send(:mailbox?, "user@#{longest_domain}")
    assert_not_mailbox listener, "user@#{longest_domain}.a"
  end

  private
    def start_listener(**overrides)
      start(MailGate::Listener, backend: @backend, hostname: "mx.test", max_recipients: 100,
        max_message_size: 10_000, max_connections: 10, max_processings: 2, stress_threshold: nil,
        auth: :disabled, starttls: :optional, **overrides)
    end

    def assert_not_mailbox(listener, address)
      refute listener.send(:mailbox?, address), "#{address.inspect} passed as a mailbox"
    end

    def peer_certificate
      connect do |socket|
        read_smtp_response(socket)
        socket.write "EHLO probe.example\r\n"
        read_smtp_lines(socket)
        starttls(socket).peer_cert
      end
    end
end
