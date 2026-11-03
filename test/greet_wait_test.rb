require "test_helper"

class MailGate::GreetWaitTest < MailGate::ListenerTestCase
  # Answers no PTR, a second late when stalled, recording when it was asked and the thread it ran on.
  class RecordingResolver
    attr_reader :asked_at, :threads

    def initialize(stall: false)
      @stall = stall
      @threads = Queue.new
    end

    def ptr(_address)
      @asked_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @threads << Thread.current
      sleep 1 if @stall
      raise MailResolver::NoSuchName, "none"
    end
  end

  def setup
    @backend = MailGate::FakeBackend.new
    @backend.routes = { "everyone@one.example" => :one_mailbox }
  end

  def test_holds_the_banner_for_the_greet_wait_and_looks_up_reverse_dns_only_after_it
    resolver = RecordingResolver.new
    start_mx(greet_wait: 0.5, resolver:)

    connect do |socket|
      connected_at = monotonic_time
      assert_equal "220 mx.test ESMTP\r\n", socket.gets
      banner_at = monotonic_time

      assert_operator banner_at - connected_at, :>=, 0.5
      resolver.threads.pop(timeout: 1)
      assert_operator resolver.asked_at, :>=, connected_at + 0.5
    end
  end

  def test_refuses_and_drops_a_client_that_talks_before_the_banner
    log = StringIO.new
    resolver = RecordingResolver.new(stall: true)
    start_mx(greet_wait: 2, resolver:, reverse_dns_timeout: 30, logger: Logger.new(log))

    connect do |socket|
      socket.write "EHLO hasty.example\r\n"

      assert_equal "554 5.7.1 Protocol error: talking before the greeting\r\n", socket.gets
      assert_nil socket.gets
    end

    assert_match(/\[127\.0\.0\.1\] Client talked before the banner/, log.string)
    assert_nil resolver.asked_at, "looked up a client that talked first"
    assert_empty @backend.calls
    assert_empty @backend.errors
  end

  def test_lets_a_client_that_hangs_up_during_the_wait_go_quietly
    resolver = RecordingResolver.new(stall: true)
    start_mx(greet_wait: 2, resolver:, reverse_dns_timeout: 30)

    connect { |socket| socket.close_write }

    assert lookup_ended?(resolver), "lookup thread outlived the connection"
    assert_empty @backend.errors
  end

  def test_shortens_the_wait_under_stress
    start_mx(greet_wait: 30)
    @listener.define_singleton_method(:stressed?) { true }

    connect do |socket|
      connected_at = monotonic_time
      assert_match(/\A220 /, socket.gets)
      assert_in_delta MailGate::Listener::STRESS_GREET_WAIT, monotonic_time - connected_at, 0.5
    end
  end

  def test_mx_waits_by_default_and_submission_does_not
    mx = MailGate::MxListener.new(**mx_options)
    submission = MailGate::SubmissionListener.new(backend: @backend, hostname: "submission.test", host: "127.0.0.1",
      port: 1, max_message_size: 10_000, max_recipients: 50, max_processings: 2, max_connections: 10,
      max_connections_per_ip: 10, max_tls_sessions_per_ip: nil, max_auth_attempts_per_ip: nil, stress_threshold: nil)

    assert_equal 6, mx.instance_variable_get(:@greet_wait)
    assert_nil submission.instance_variable_get(:@greet_wait)
  end

  private
    def start_mx(**overrides)
      start(MailGate::MxListener, **mx_options.except(:host, :port), **overrides)
    end

    def mx_options
      { backend: @backend, hostname: "mx.test", host: "127.0.0.1", port: 1, max_message_size: 10_000, max_recipients: 50,
        max_processings: 2, max_connections: 10, max_connections_per_ip: 10, max_messages_per_ip: nil,
        max_tls_sessions_per_ip: nil, stress_threshold: nil }
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # A lookup cancelled before it reached the resolver never registered.
    def lookup_ended?(resolver)
      thread = resolver.threads.pop(timeout: 0.5)
      thread.nil? || !thread.join(2).nil?
    end
end
