require "test_helper"

class MailGate::ErrorLimitsTest < MailGate::ListenerTestCase
  RAW = "Subject: Hi\r\n\r\nBody.\r\n"

  def setup
    @backend = MailGate::FakeBackend.new
    @backend.routes = { "everyone@one.example" => :one_mailbox }
  end

  def test_sleeps_before_each_error_reply_past_the_soft_limit
    start_mx(soft_error_limit: 2, error_sleep_time: 0.4)

    connect do |socket|
      socket.gets
      2.times { assert_operator timed { assert_match(/\A500/, command(socket, "BOGUS")) }, :<, 0.3 }
      assert_operator timed { assert_match(/\A500/, command(socket, "BOGUS")) }, :>=, 0.4
    end
  end

  def test_drops_the_connection_with_a_421_at_the_hard_limit
    start_mx(hard_error_limit: 3)

    connect do |socket|
      socket.gets
      2.times { assert_match(/\A500/, command(socket, "BOGUS")) }

      assert_match(/\A500/, command(socket, "BOGUS"))
      assert_match(/\A421/, socket.gets)
      assert_nil socket.gets
    end
  end

  def test_drops_the_connection_at_the_first_error_under_stress
    start_mx
    @listener.define_singleton_method(:stressed?) { true }

    connect do |socket|
      socket.gets
      assert_match(/\A500/, command(socket, "BOGUS"))
      assert_match(/\A421/, socket.gets)
    end
  end

  def test_sleeps_on_a_refused_message_with_its_processing_slot_already_free
    start_mx(soft_error_limit: 1, error_sleep_time: 1, max_processings: 1)
    looping = Array.new(5) { |i| "Received: from relay#{i}.example by mx.test with ESMTP; Wed, 01 Jan 2025 00:00:00 +0000\r\n" }.join

    connect do |socket|
      socket.gets
      command socket, "BOGUS"
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RCPT TO:<everyone@one.example>"
      command socket, "DATA"

      sent_at = monotonic_time
      socket.write "#{looping}#{RAW}.\r\n"
      sleep 0.4
      assert_equal 0, @listener.processings_count

      assert_match(/\A554/, socket.gets)
      assert_operator monotonic_time - sent_at, :>=, 1
    end
  end

  def test_both_listeners_share_the_default_error_limits
    mx = MailGate::MxListener.new(backend: @backend, hostname: "mx.test", host: "127.0.0.1", port: 1,
      max_message_size: 10_000, max_recipients: 50, max_processings: 2, max_connections: 10, max_connections_per_ip: 10,
      max_messages_per_ip: nil, max_tls_sessions_per_ip: nil, stress_threshold: nil)
    submission = MailGate::SubmissionListener.new(backend: @backend, hostname: "submission.test", host: "127.0.0.1",
      port: 1, max_message_size: 10_000, max_recipients: 50, max_processings: 2, max_connections: 10,
      max_connections_per_ip: 10, max_tls_sessions_per_ip: nil, max_auth_attempts_per_ip: nil, stress_threshold: nil)

    [ mx, submission ].each do |listener|
      assert_equal [ 1, 10, 20 ], %i[ @error_sleep_time @error_sleep_after @max_exceptions ].map { |name| listener.instance_variable_get(name) }
    end
  end

  private
    def start_mx(**overrides)
      start(MailGate::MxListener, backend: @backend, hostname: "mx.test", max_message_size: 10_000, max_recipients: 50,
        max_processings: 2, max_connections: 10, max_connections_per_ip: 10, max_messages_per_ip: nil,
        max_tls_sessions_per_ip: nil, stress_threshold: nil, **overrides)
    end

    def timed
      started = monotonic_time
      yield
      monotonic_time - started
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
