require "test_helper"

class MailGate::InstrumentTest < MailGate::ListenerTestCase
  RAW = "Subject: Hi\r\n\r\nBody.\r\n"
  TOKEN = "secret-token"
  CONFIRMED = { "127.0.0.1" => { ptr: [ "mail.sender.example" ] }, "mail.sender.example" => { a: [ "127.0.0.1" ] } }.freeze

  Verdict = Data.define(:action, :score)

  # Records every event, from whichever connection thread sends it.
  class Recorder
    def initialize
      @events = []
      @lock = Mutex.new
    end

    def call(event, **data)
      @lock.synchronize { @events << [ event, data ] }
    end

    def events
      @lock.synchronize { @events.dup }
    end
  end

  class Scorer
    attr_accessor :verdict, :failure

    def check(_raw, _envelope, budget:)
      raise @failure if @failure

      @verdict
    end
  end

  def setup
    @recorder = Recorder.new
    @backend = MailGate::FakeBackend.new
    @backend.routes = { "everyone@one.example" => :one_mailbox, "everyone@two.example" => :two_mailbox }
    @backend.tokens = { TOKEN => "token-1" }
    @backend.senders = { "token-1" => [ "sender@example.com" ] }
  end

  def test_refuses_an_event_missing_from_the_list
    listener = MailGate::Listener.allocate
    listener.instance_variable_set(:@instrument, Recorder.new)

    assert_raises(ArgumentError) { listener.send(:instrument, :unlisted) }
  end

  def test_follows_a_delivered_message_with_plain_data
    scorer = Scorer.new
    scorer.verdict = Verdict.new(action: :add_header, score: 6.5)
    start_mx(scorer:, scan_budget: 8, resolver: MailResolver::Testing::FakeResolver.new(CONFIRMED))

    deliver_mx(to: %w[ everyone@one.example everyone@two.example ])

    queue_id = @backend.stored.first[:envelope].queue_id
    assert_equal [ :connection_accepted, :reverse_dns_finished, :scorer_finished, :message_accepted ], @recorder.events.map(&:first) - [ :replied ]
    assert_equal({ ip: "127.0.0.1" }, data(:connection_accepted))
    assert_equal({ ip: "127.0.0.1", outcome: :verified }, data(:reverse_dns_finished).except(:duration))
    assert_equal({ ip: "127.0.0.1", queue_id:, action: :add_header, score: 6.5 }, data(:scorer_finished).except(:duration))
    assert_equal({ ip: "127.0.0.1", queue_id:, bytes: RAW.bytesize, recipients: 2 }, data(:message_accepted))
    assert_kind_of Float, data(:reverse_dns_finished)[:duration]
    assert_kind_of Float, data(:scorer_finished)[:duration]
  end

  def test_tells_an_unknown_client_from_a_temporary_failure
    start_mx(resolver: MailResolver::Testing::FakeResolver.new("127.0.0.1" => { ptr: [ "forged.example" ] }))
    deliver_mx
    assert_equal :unknown, data(:reverse_dns_finished)[:outcome]

    @recorder = Recorder.new
    restart_listener(resolver: MailResolver::Testing::FakeResolver.new("127.0.0.1" => { ptr: :servfail }))
    deliver_mx
    assert_equal :temporary_failure, data(:reverse_dns_finished)[:outcome]
  end

  def test_names_the_error_a_scorer_failed_with
    scorer = Scorer.new
    scorer.failure = Errno::ECONNREFUSED.new
    start_mx(scorer:, scan_budget: 8)

    deliver_mx

    failed = data(:scorer_failed)
    assert_equal({ ip: "127.0.0.1", queue_id: @backend.stored.first[:envelope].queue_id, error: "Errno::ECONNREFUSED" },
      failed.except(:duration))
    assert_kind_of Float, failed[:duration]
    assert_nil data(:scorer_finished)
  end

  def test_tells_of_a_client_refused_for_talking_first
    start_mx(greet_wait: 2)

    connect do |socket|
      socket.write "EHLO hasty.example\r\n"
      assert_match(/\A554/, socket.gets)
    end

    assert_equal({ ip: "127.0.0.1" }, data(:pregreet_refused))
  end

  def test_tells_of_each_per_ip_rate_and_which_one
    start_mx(max_messages_per_ip: 1, max_tls_sessions_per_ip: 1)

    connect do |socket|
      read_smtp_response(socket)
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RSET"
      assert_match(/\A450/, command(socket, "MAIL FROM:<sender@example.com>"))
    end
    2.times do
      connect do |socket|
        read_smtp_response(socket)
        socket.write "EHLO test.client.example\r\n"
        read_smtp_lines(socket)
        command socket, "STARTTLS"
      end
    end

    assert_equal [ { ip: "127.0.0.1", limit: :messages_per_ip }, { ip: "127.0.0.1", limit: :tls_sessions_per_ip } ], all(:rate_limited)
  end

  def test_tells_of_a_message_refused_past_the_per_ip_processings_cap
    start_mx(max_processings_per_ip: 1)

    connect do |first|
      first.gets
      [ "HELO test.client.example", "MAIL FROM:<sender@example.com>", "RCPT TO:<everyone@one.example>" ].each { command first, it }
      assert_match(/\A354/, command(first, "DATA"))

      connect do |second|
        second.gets
        [ "HELO test.client.example", "MAIL FROM:<sender@example.com>", "RCPT TO:<everyone@one.example>" ].each { command second, it }
        assert_match(/\A451 4\.7\.0/, command(second, "DATA"))
      end
    end

    assert_equal [ { ip: "127.0.0.1", limit: :processings_per_ip } ], all(:rate_limited)
  end

  def test_tells_of_submission_logins_and_limits_without_the_account
    start_submission(max_auth_attempts_per_ip: 2)

    with_encrypted_session do |ssl|
      assert_match(/\A535/, command(ssl, "AUTH PLAIN #{credential("wrong")}"))
      assert_match(/\A235/, command(ssl, "AUTH PLAIN #{credential(TOKEN)}"))
    end
    with_encrypted_session { |ssl| assert_match(/\A454/, command(ssl, "AUTH PLAIN #{credential(TOKEN)}")) }

    assert_equal [ { ip: "127.0.0.1" } ], all(:auth_failed)
    assert_equal [ { ip: "127.0.0.1" } ], all(:auth_succeeded)
    assert_equal [ { ip: "127.0.0.1", limit: :auth_attempts_per_ip } ], all(:rate_limited)
  end

  def test_tells_of_a_rate_limited_account
    @backend.rate_limited = true
    start_submission

    with_encrypted_session do |ssl|
      command ssl, "AUTH PLAIN #{credential(TOKEN)}"
      assert_match(/\A452/, command(ssl, "MAIL FROM:<sender@example.com>"))
    end

    assert_equal [ { ip: "127.0.0.1", limit: :account } ], all(:rate_limited)
    assert_nil data(:message_accepted)
  end

  def test_tells_of_a_submitted_message
    start_submission

    smtp = Net::SMTP.new("127.0.0.1", @port)
    smtp.enable_starttls(insecure_tls_context)
    smtp.start do
      smtp.authenticate("smtp", TOKEN, :plain)
      smtp.send_message(RAW, "sender@example.com", "recipient@example.com")
    end

    assert_equal({ ip: "127.0.0.1", queue_id: @backend.submitted.first[:envelope].queue_id, bytes: RAW.bytesize, recipients: 1 },
      data(:message_accepted))
  end

  def test_tells_of_each_reply_by_its_code
    start_mx(greet_wait: nil)

    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "BOGUS"
      command socket, "QUIT"
    end

    eventually { all(:replied).size == 4 }
    assert_equal [ 220, 250, 500, 221 ].map { { ip: "127.0.0.1", code: it } }, all(:replied)
  end

  def test_tells_of_a_connection_refused_past_the_per_ip_cap_and_its_reply
    start_mx(max_connections_per_ip: 1)

    connect do |first|
      first.gets
      connect { |second| assert_match(/\A421/, second.gets) }
    end

    eventually { all(:replied).size == 2 }
    assert_equal [ { ip: "127.0.0.1", limit: :max_connections_per_ip } ], all(:connection_refused)
    assert_equal [ { ip: "127.0.0.1" } ], all(:connection_accepted)
    assert_includes all(:replied), { ip: "127.0.0.1", code: 421 }
  end

  def test_tells_of_a_connection_refused_past_the_global_cap
    start_mx(max_connections: 1)

    connect do |first|
      first.gets
      connect { |second| assert_match(/\A421/, second.gets) }
    end

    eventually { all(:connection_refused).any? }
    assert_equal [ { ip: "127.0.0.1", limit: :max_connections } ], all(:connection_refused)
  end

  def test_tells_of_each_tarpitted_error_and_the_hard_limit
    start_mx(soft_error_limit: 1, error_sleep_time: 0.1, hard_error_limit: 3)

    connect do |socket|
      socket.gets
      3.times { assert_match(/\A500/, command(socket, "BOGUS")) }
      assert_match(/\A421/, socket.gets)
    end

    assert_equal [ { ip: "127.0.0.1", duration: 0.1 } ] * 2, all(:error_tarpitted)
    assert_equal [ { ip: "127.0.0.1" } ], all(:error_limit_reached)
  end

  def test_reports_a_failing_hook_and_carries_on
    failure = RuntimeError.new("metrics down")
    start_mx(instrument: ->(_event, **) { raise failure })

    deliver_mx

    assert_equal 1, @backend.stored.size
    assert_includes @backend.errors, failure
  end

  private
    def start_mx(**overrides)
      start(MailGate::MxListener, backend: @backend, hostname: "mx.test", max_message_size: 10_000, max_recipients: 50,
        max_processings: 2, max_connections: 10, max_connections_per_ip: 10, max_messages_per_ip: nil,
        max_tls_sessions_per_ip: nil, stress_threshold: nil, instrument: @recorder, **overrides)
    end

    def start_submission(**overrides)
      start(MailGate::SubmissionListener, backend: @backend, hostname: "submission.test", max_message_size: 10_000,
        max_recipients: 50, max_processings: 2, max_connections: 10, max_connections_per_ip: 10,
        max_tls_sessions_per_ip: nil, max_auth_attempts_per_ip: nil, stress_threshold: nil, instrument: @recorder, **overrides)
    end

    def restart_listener(**overrides)
      @listener.stop
      start_mx(**overrides)
    end

    def deliver_mx(to: "everyone@one.example")
      smtp = Net::SMTP.new("127.0.0.1", @port)
      smtp.disable_starttls
      smtp.start("test.client.example") { smtp.send_message(RAW, "sender@example.com", to) }
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

    def credential(token)
      Base64.strict_encode64("\0smtp\0#{token}")
    end

    # A reply is observed once written, and a refusal at max_connections once closed, so the client can read first.
    def eventually
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end

    def data(event)
      all(event).first
    end

    def all(event)
      @recorder.events.filter_map { |name, data| data if name == event }
    end
end
