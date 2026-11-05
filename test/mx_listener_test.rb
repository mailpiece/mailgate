require "test_helper"

class MailGate::MxListenerTest < MailGate::ListenerTestCase
  RAW = "Subject: Hi\r\n\r\nBody.\r\n"

  # Answers a name for every client after a delay, recording each query and the thread it ran on.
  class SlowResolver
    attr_reader :queries, :threads

    def initialize(delay:)
      @delay = delay
      @queries = Queue.new
      @threads = Queue.new
    end

    def ptr(address)
      @queries << [ :ptr, address ]
      @threads << Thread.current
      sleep @delay
      [ "slow.example" ]
    end

    def a(name)
      @queries << [ :a, name ]
      [ "127.0.0.1" ]
    end
  end

  # Stands in for a PTR zone whose nameserver never answers, until the test lets every query go.
  class BlackholeResolver
    attr_reader :waiting

    def initialize
      @waiting = Queue.new
      @answered = Queue.new
    end

    def ptr(_address)
      @waiting << Thread.current
      @answered.pop
      []
    end

    def answer
      @waiting.size.times { @answered << true }
    end
  end

  def setup
    @backend = MailGate::FakeBackend.new
    @backend.routes = { "everyone@one.example" => :one_mailbox, "postmaster@one.example" => :one_postmaster,
      "everyone@two.example" => :two_mailbox }
    start_listener
  end

  def test_passes_max_processings_wait_to_the_engine
    assert_equal 30, @listener.instance_variable_get(:@max_processings_wait)

    restart_listener(max_processings_wait: 5)

    assert_equal 5, @listener.instance_variable_get(:@max_processings_wait)
  end

  def test_defaults_every_option_but_the_backend
    listener = MailGate::MxListener.new(backend: @backend)

    assert_equal Socket.gethostname, listener.hostname
    assert_equal [ [ "0.0.0.0", 25 ] ], listener.instance_variable_get(:@addresses)
    assert_equal 10_240_000, listener.max_message_size
    assert_equal 1000, listener.max_recipients
    assert_equal 1000, listener.instance_variable_get(:@recipient_limit)
    assert_equal 10, listener.max_processings
    assert_equal 5, listener.instance_variable_get(:@max_processings_per_ip)
    assert_equal 100, listener.max_connections
    assert_equal 10, listener.max_connections_per_ip
    assert_nil listener.instance_variable_get(:@max_messages_per_ip)
    assert_nil listener.instance_variable_get(:@max_tls_sessions_per_ip)
    assert_equal 1.0, listener.instance_variable_get(:@stress_threshold)
    assert_equal 180, listener.instance_variable_get(:@read_timeout)
    assert_equal 8, listener.instance_variable_get(:@scan_budget)
  end

  def test_overrides_each_default
    listener = MailGate::MxListener.new(backend: @backend, hostname: "mx.example", host: "127.0.0.1", port: 2525,
      max_message_size: 5_000, max_recipients: 50, max_processings: 3, max_connections: 20, max_connections_per_ip: 4,
      max_messages_per_ip: 30, max_tls_sessions_per_ip: 60, stress_threshold: 0.8, scorer: Object.new, scan_budget: 2)

    assert_equal "mx.example", listener.hostname
    assert_equal [ [ "127.0.0.1", 2525 ] ], listener.instance_variable_get(:@addresses)
    assert_equal 5_000, listener.max_message_size
    assert_equal 50, listener.instance_variable_get(:@recipient_limit)
    assert_equal 3, listener.max_processings
    assert_equal 1, listener.instance_variable_get(:@max_processings_per_ip)
    assert_equal 20, listener.max_connections
    assert_equal 4, listener.max_connections_per_ip
    assert_equal 30, listener.instance_variable_get(:@max_messages_per_ip)
    assert_equal 60, listener.instance_variable_get(:@max_tls_sessions_per_ip)
    assert_equal 0.8, listener.instance_variable_get(:@stress_threshold)
    assert_equal 2, listener.instance_variable_get(:@scan_budget)
  end

  def test_takes_max_processings_per_ip_over_half_of_max_processings
    assert_equal 4, MailGate::MxListener.new(backend: @backend, max_processings_per_ip: 4).instance_variable_get(:@max_processings_per_ip)
    assert_nil MailGate::MxListener.new(backend: @backend, max_processings_per_ip: nil).instance_variable_get(:@max_processings_per_ip)
  end

  def test_refuses_a_client_past_its_default_share_of_connections
    restart_listener(max_connections: 100, max_connections_per_ip: MailGate::MxListener::DEFAULTS[:max_connections_per_ip])

    held = 10.times.map { Socket.tcp("127.0.0.1", @port).tap(&:gets) }
    connect { |socket| assert_match(/\A421 /, socket.gets.to_s) }
    held.pop.close
    sleep 0.1
    connect { |socket| assert_match(/\A220 /, socket.gets.to_s) }
  ensure
    held&.each(&:close)
  end

  def test_refuses_a_client_more_messages_at_once_than_its_share_of_processings
    restart_listener(max_processings: 5)

    trickling = 2.times.map { open_data.tap { |socket, reply| assert_match(/\A354/, reply) }.first }
    socket, reply = open_data
    assert_match(/\A451 4\.7\.0 /, reply)

    trickling.pop.close
    sleep 0.1
    assert_match(/\A354/, command(socket, "DATA"))
    assert_match(/\A250/, command(socket, "#{RAW}."))
    trickling.first.write("#{RAW}.\r\n")
    assert_match(/\A250/, trickling.first.gets)
    assert_equal 2, @backend.stored.size
  ensure
    [ *trickling, socket ].compact.each(&:close)
  end

  def test_refuses_the_recipient_past_the_default_limit
    restart_listener(max_recipients: MailGate::MxListener::DEFAULTS[:max_recipients])
    @backend.routes = (1..1000).to_h { |n| [ "user#{n}@one.example", :mailbox ] }

    connect do |socket|
      read_smtp_response(socket)
      command socket, "EHLO client.example"
      read_smtp_lines(socket)
      command socket, "MAIL FROM:<sender@example.com>"
      replies = (1..1001).map { |n| command socket, "RCPT TO:<user#{n}@one.example>" }

      assert replies.first(1000).all? { |reply| reply.start_with?("250") }
      assert_match(/\A452 /, replies.last)
    end
  end

  def test_stores_a_message_for_a_routed_recipient
    deliver(to: "everyone@one.example")

    stored = sole(@backend.stored)
    assert_equal :one_mailbox, stored[:route]
    assert_equal "everyone@one.example", stored[:rcpt_to]
    assert_equal "sender@example.com", stored[:envelope].mail_from
    assert_equal "127.0.0.1", stored[:envelope].ip
    assert_equal "test.client.example", stored[:envelope].helo
    assert stored[:raw].end_with?(RAW)
    assert_nil stored[:verdict]
  end

  def test_refuses_a_recipient_without_a_route
    error = assert_raises(Net::SMTPFatalError) { deliver(to: "nobody@unknown.example") }

    assert_match "550", error.message
    assert_empty @backend.stored
  end

  def test_stores_one_message_per_recipient_under_each_recipients_own_route_with_one_reply
    response = deliver(to: %w[ everyone@one.example everyone@two.example ])

    assert_equal "250", response.status
    assert_equal [ [ :one_mailbox, "everyone@one.example" ], [ :two_mailbox, "everyone@two.example" ] ],
      @backend.stored.map { |stored| stored.values_at(:route, :rcpt_to) }
    assert_equal 1, @backend.stored.map { |stored| stored[:raw] }.uniq.size
  end

  def test_accepts_a_repeated_recipient_but_routes_and_stores_it_once
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      replies = [ *([ "RCPT TO:<everyone@one.example>" ] * 40), "RCPT TO:<everyone@ONE.Example>" ].map { |line| command socket, line }
      assert replies.all? { |reply| reply.start_with?("250") }
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
    end

    stored = sole(@backend.stored)
    assert_equal [ "everyone@one.example" ], stored[:envelope].rcpt_to
    assert_equal 1, @backend.calls.count { |call| call.first == :route }
  end

  def test_stores_once_for_recipients_that_share_a_route
    @backend.routes["alias@one.example"] = :one_mailbox

    deliver(to: %w[ everyone@one.example alias@one.example everyone@two.example ])

    assert_equal [ [ :one_mailbox, "everyone@one.example" ], [ :two_mailbox, "everyone@two.example" ] ],
      @backend.stored.map { |stored| stored.values_at(:route, :rcpt_to) }
    assert_equal %w[ everyone@one.example alias@one.example everyone@two.example ], @backend.stored.first[:envelope].rcpt_to
  end

  def test_carries_no_route_from_one_transaction_into_the_next_on_the_same_connection
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RCPT TO:<everyone@one.example>"
      command socket, "RSET"
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RCPT TO:<everyone@two.example>"
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RCPT TO:<postmaster@one.example>"
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
    end

    assert_equal [ [ :two_mailbox ], [ :one_postmaster ] ], @backend.stored.map { |stored| [ stored[:route] ] }
  end

  def test_gives_each_message_its_own_queue_id_shared_by_its_recipients
    deliver(to: %w[ everyone@one.example everyone@two.example ])
    deliver(to: "everyone@one.example")

    queue_ids = @backend.stored.map { |stored| stored[:envelope].queue_id }
    assert_match(/\A[A-Z0-9]{12}\z/, queue_ids.first)
    assert_equal queue_ids[0], queue_ids[1]
    refute_equal queue_ids[0], queue_ids[2]
  end

  def test_logs_a_message_under_its_queue_id_through_its_reply_but_not_a_refused_sender
    log = StringIO.new
    restart_listener(logger: Logger.new(log))

    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      command socket, "RCPT TO:<everyone@one.example>"
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
      @backend.storage_full = true
      assert_match(/\A452/, command(socket, "MAIL FROM:<sender@example.com>"))
    end

    queue_id = sole(@backend.stored)[:envelope].queue_id
    assert_match(/\[#{queue_id}\] \[smtp\] MailGate::MxListener accepted/, log.string)
    assert_match(/\[#{queue_id}\] >>> 250 2\.0\.0 Requested mail action okay/, log.string)
    assert_match(/\] Storage limit reached/, log.string)
    refute_match(/\[#{queue_id}\] Storage limit reached/, log.string)
  end

  def test_lists_no_more_than_ten_recipients_in_the_accepted_log_line
    log = StringIO.new
    restart_listener(logger: Logger.new(log))
    recipients = (1..15).map { |n| "user#{n}@one.example" }
    @backend.routes = recipients.to_h { |recipient| [ recipient, recipient.to_sym ] }

    deliver(to: recipients)

    assert_match(/accepted \d+ bytes from sender@example\.com to #{Regexp.escape(recipients.first(10).join(", "))} and 5 more$/, log.string)
  end

  def test_one_failed_recipient_answers_the_whole_message_with_a_451_and_reports_it
    @backend.fail_at :store, RuntimeError.new("boom")

    error = assert_raises(Net::SMTPServerBusy) { deliver(to: %w[ everyone@one.example everyone@two.example ]) }

    assert_match "451", error.message
    assert_equal [ "boom" ], @backend.errors.map(&:message)
  end

  def test_refuses_recipients_past_the_cap_with_a_452
    restart_listener(max_recipients: 2)

    error = assert_raises(Net::SMTPServerBusy) do
      deliver(to: %w[ everyone@one.example postmaster@one.example everyone@two.example ])
    end

    assert_match "452", error.message
    assert_empty @backend.stored
  end

  def test_accepts_recipients_up_to_the_cap
    restart_listener(max_recipients: 2)

    deliver(to: %w[ everyone@one.example postmaster@one.example ])

    assert_equal 2, @backend.stored.size
  end

  def test_refuses_mail_at_mail_from_with_a_452_while_storage_is_full
    @backend.storage_full = true

    error = assert_raises(Net::SMTPServerBusy) { deliver(to: "everyone@one.example") }

    assert_match "452", error.message
    assert_equal [ [ :storage_full? ] ], @backend.calls
  end

  def test_refuses_a_full_mailbox_with_a_452_for_that_recipient_alone
    mailbox_full = Class.new(MailSmtp::Error) { status 452, "Requested mail action not taken: mailbox full", enhanced: "4.2.2" }
    @backend.routes["everyone@two.example"] = mailbox_full.new("over quota")

    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"
      assert_equal "452 4.2.2 Requested mail action not taken: mailbox full", command(socket, "RCPT TO:<everyone@two.example>").chomp
      assert_match(/\A250/, command(socket, "RCPT TO:<everyone@one.example>"))
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
    end

    assert_equal [ :one_mailbox ], @backend.stored.map { |stored| stored[:route] }
    assert_equal [ "everyone@one.example" ], @backend.stored.first[:envelope].rcpt_to
    assert_empty @backend.errors
  end

  def test_reports_a_backend_error_in_the_envelope_phase_and_asks_the_sender_to_retry
    @backend.fail_at :route, RuntimeError.new("boom")

    # A 5xx here would permanently abandon mail we could still take tomorrow.
    error = assert_raises(Net::SMTPServerBusy) { deliver(to: "everyone@one.example") }

    assert_match "451", error.message
    assert_equal [ "boom" ], @backend.errors.map(&:message)
  end

  def test_strips_every_inbound_authentication_results_before_storing
    deliver(to: "everyone@one.example",
      raw: "Authentication-Results: mx.test; dkim=pass header.d=trusted.example\r\n#{RAW}")

    refute_includes sole(@backend.stored)[:raw], "trusted.example"
  end

  def test_strips_an_authentication_results_folded_before_its_colon
    deliver(to: "everyone@one.example",
      raw: "Authentication-Results\r\n : mx.test; dkim=pass header.d=bank.example\r\nFrom: ceo@bank.example\r\n#{RAW}")

    stored = sole(@backend.stored)[:raw]
    refute_includes stored, "bank.example; dkim"
    refute_match(/^Authentication-Results/i, stored)
    assert_includes stored, "From: ceo@bank.example\r\n"
  end

  def test_refuses_a_header_section_past_its_cap_with_a_552
    restart_listener(max_message_size: 1_000_000)
    header_lines = "X-Pad: #{"p" * 990}\r\n" * 300

    connect do |socket|
      socket.gets
      [ "HELO test.client.example", "MAIL FROM:<sender@example.com>", "RCPT TO:<everyone@one.example>", "DATA" ].each do |line|
        command socket, line
      end

      assert_match(/\A552 5\.3\.4 /, command(socket, "#{header_lines}\r\nBody.\r\n."))
    end

    assert_empty @backend.stored
  end

  def test_ends_the_header_section_before_a_first_line_that_would_fold_into_our_received
    stamps = "Received: by mx.test with ESMTP; Wed, 01 Jan 2025 00:00:00 +0000\r\n" * 5
    folded = [ "\tby mx.test with ESMTPS; Mon, 1 Jan 2024 00:00:00 +0000\r\n#{RAW}",
      " (trusted)\r\nAuthentication-Results: mx.test; dkim=pass\r\n#{stamps}#{RAW}" ]

    folded.each { |raw| deliver(to: "everyone@one.example", raw:) }

    @backend.stored.zip(folded).each do |stored, raw|
      assert_match(/\AReceived: [^\r\n]+\r\n\r\n#{Regexp.escape(raw)}\z/, stored[:raw])
    end
  end

  def test_store_gets_everything_a_backend_needs_to_authenticate_the_message
    signed = "DKIM-Signature: v=1; a=rsa-sha256; d=sender.example; s=s1;\r\n\th=from:subject; bh=abc=; b=def=\r\n" \
      "ARC-Seal: i=1; a=rsa-sha256; d=forwarder.example; s=a1; cv=none; b=ghi=\r\n" \
      "ARC-Authentication-Results: i=1; forwarder.example; spf=pass\r\n" \
      "From: Sender <sender@sender.example>\r\nSubject: Hi\r\n\r\nBody with trailing space \r\n\r\n"
    deliver(to: "everyone@one.example", from: "bounce@sender.example", helo: "mail.sender.example",
      raw: "Authentication-Results: mx.test; dkim=pass\r\n#{signed}")

    stored = sole(@backend.stored)
    assert_equal [ "127.0.0.1", "mail.sender.example", "bounce@sender.example" ],
      stored[:envelope].to_h.values_at(:ip, :helo, :mail_from)
    assert_match(/\AReceived: [^\r\n]+\r\n#{Regexp.escape(signed)}\z/, stored[:raw])
  end

  def test_gives_a_retry_of_the_same_message_the_same_digest
    2.times { deliver(to: "everyone@one.example") }
    deliver(to: "everyone@one.example", raw: "Subject: Other\r\n\r\nBody.\r\n")
    deliver(to: "everyone@one.example", from: "other@example.com")

    digests = @backend.stored.map { |stored| stored[:digest] }
    assert_equal digests[0], digests[1]
    assert_equal 3, digests.uniq.size
  end

  def test_detects_a_loop_even_when_our_own_stamp_sits_on_a_folded_line
    folded_stamps = Array.new(5) do |i|
      "Received: from relay#{i}.example (relay#{i}.example [10.0.0.#{i}])\r\n" \
        "\tby mx.test with ESMTP; Wed, 01 Jan 2025 00:00:0#{i} +0000\r\n"
    end.join

    error = assert_raises(Net::SMTPFatalError) { deliver(to: "everyone@one.example", raw: "#{folded_stamps}#{RAW}") }

    assert_match "554", error.message
    assert_empty @backend.stored
  end

  def test_stamps_the_helo_and_unknown_for_a_client_without_reverse_dns
    deliver(to: "everyone@one.example", helo: "friendly.sender.example")

    stored = sole(@backend.stored)
    assert_match(/\AReceived: from friendly\.sender\.example \(unknown \[127\.0\.0\.1\]\) by mx\.test with ESMTP; .* \+0000\r\n/, stored[:raw])
    assert_equal 1, stored[:raw][/\AReceived:.*?\r\n/m].count("\n")
    assert_equal "unknown", stored[:envelope].hostname
  end

  def test_stamps_and_hands_over_the_forward_confirmed_name
    restart_listener(resolver: MailResolver::Testing::FakeResolver.new(
      "127.0.0.1" => { ptr: [ "mail.sender.example." ] }, "mail.sender.example" => { a: [ "127.0.0.1" ] }))

    deliver(to: "everyone@one.example", helo: "friendly.sender.example")

    stored = sole(@backend.stored)
    assert_match(/\AReceived: from friendly\.sender\.example \(mail\.sender\.example \[127\.0\.0\.1\]\) by mx\.test /, stored[:raw])
    assert_equal "mail.sender.example", stored[:envelope].hostname
  end

  def test_logs_a_temporary_reverse_dns_failure_apart_from_a_missing_name
    log = StringIO.new
    restart_listener(logger: Logger.new(log), resolver: MailResolver::Testing::FakeResolver.new("127.0.0.1" => { ptr: :servfail }))

    deliver(to: "everyone@one.example")

    assert_equal "unknown", sole(@backend.stored)[:envelope].hostname
    assert_match(/WARN -- : \[127\.0\.0\.1\] .*Reverse DNS failed temporarily: server failure/, log.string)
    assert_empty @backend.errors
  end

  def test_waits_no_longer_than_the_reverse_dns_timeout
    restart_listener(resolver: SlowResolver.new(delay: 1), reverse_dns_timeout: 0.3)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deliver(to: "everyone@one.example")

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal "unknown", sole(@backend.stored)[:envelope].hostname
  end

  def test_ends_the_lookup_when_the_client_leaves_before_it_is_needed
    resolver = SlowResolver.new(delay: 0.3)
    restart_listener(resolver:, reverse_dns_timeout: 30)

    connect do |socket|
      read_smtp_response(socket)
      command socket, "QUIT"
    end

    thread = resolver.threads.pop(timeout: 0.5)
    assert thread.nil? || thread.join(1), "lookup thread outlived the connection"
    assert_equal 1, resolver.queries.size, "a forward query started after the client left"
  end

  def test_holds_no_more_reverse_dns_lookups_than_connections_however_fast_clients_come_and_go
    resolver = BlackholeResolver.new
    restart_listener(resolver:, reverse_dns_timeout: 30, max_connections: 10)

    40.times { connect { |socket| socket.gets } }
    sleep 0.2

    assert_operator resolver.waiting.size, :<=, 10
  ensure
    resolver&.answer
  end

  def test_stamps_esmtps_after_starttls
    smtp = Net::SMTP.new("127.0.0.1", @port)
    smtp.enable_starttls(insecure_tls_context)
    smtp.start { smtp.send_message(RAW, "sender@example.com", "everyone@one.example") }

    stored = sole(@backend.stored)
    assert_match(/by mx\.test with ESMTPS; /, stored[:raw])
    assert stored[:envelope].tls_version
  end

  def test_neutralizes_injection_characters_in_the_received_header
    [
      "plain\r\nAuthentication-Results: mx.test; dkim=pass",
      "a) (b [10.0.0.1]",
      "evil.example fake-token",
      "\t\x00control",
      "x" * 5000
    ].each do |hostile|
      line = received_header(helo: hostile, remote_ip: hostile)

      assert_equal 1, line.count("\n"), "extra line from #{hostile.inspect}"
      assert line.end_with?("\r\n")
      refute_includes line, "dkim=pass", "leaked injected token from #{hostile.inspect}"
      refute_includes line, "\x00"
    end
  end

  def test_preserves_an_ipv6_literal_helo_and_rejects_a_malformed_one
    assert_includes received_header(helo: "[IPv6:2001:db8::1]", remote_ip: "203.0.113.1"),
      "from [IPv6:2001:db8::1] (unknown [203.0.113.1])"
    assert_includes received_header(helo: "", remote_ip: "203.0.113.1 x"), "from unknown (unknown [unknown])"
  end

  def test_keeps_no_recipient_across_starttls
    connect do |socket|
      read_smtp_response(socket)
      socket.write "EHLO client.example\r\n"
      read_smtp_lines(socket)
      command socket, "MAIL FROM:<pre@example.com>"
      command socket, "RCPT TO:<everyone@one.example>"
      command socket, "RSET"

      ssl = starttls(socket)
      ssl.write "EHLO client.example\r\n"
      read_smtp_lines(ssl)
      command ssl, "MAIL FROM:<post@example.com>"
      command ssl, "RCPT TO:<postmaster@one.example>"
      command ssl, "DATA"
      command ssl, "#{RAW}."
    end

    assert_equal [ "postmaster@one.example" ], @backend.stored.map { |stored| stored[:rcpt_to] }
  end

  def test_refuses_a_message_that_streams_past_the_size_limit
    restart_listener(max_message_size: 1024)

    connect do |socket|
      socket.gets
      [ "HELO test.client.example", "MAIL FROM:<sender@example.com>", "RCPT TO:<everyone@one.example>", "DATA" ].each do |line|
        command socket, line
      end

      socket.write((("x" * 998) + "\r\n") * 2)
      assert_match(/\A552/, socket.gets.to_s)
    end

    assert_empty @backend.stored
  end

  def test_advertises_the_size_limit_and_8bitmime
    connect do |socket|
      read_smtp_response(socket)
      socket.write "EHLO client.example\r\n"
      lines = read_smtp_lines(socket)

      assert_includes lines, "250-SIZE 10000"
      assert_includes lines, "250-8BITMIME"
      refute_includes lines, "250-PIPELINING"
    end
  end

  def test_accepts_a_bare_path_from_a_sender_that_omits_the_angle_brackets
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      assert_match(/\A250/, command(socket, "MAIL FROM:sender@example.com"))
      assert_match(/\A250/, command(socket, "RCPT TO:everyone@one.example"))
      command socket, "DATA"
      assert_match(/\A250/, command(socket, "#{RAW}."))
    end

    assert_equal "sender@example.com", sole(@backend.stored)[:envelope].mail_from
  end

  def test_refuses_a_sender_that_is_not_a_mailbox_bracketed_or_bare
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"

      assert_match(/\A501/, command(socket, "MAIL FROM:<a b\"c@@x>"))
      assert_match(/\A501/, command(socket, "MAIL FROM:a b\"c@@x"))
    end
  end

  def test_accepts_the_null_reverse_path_which_is_how_bounces_arrive
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"

      assert_match(/\A250/, command(socket, "MAIL FROM:<>"))
    end
  end

  # 550 rather than 501: RFC 5321 §4.5.1 makes it well-formed, only unroutable.
  def test_refuses_a_domainless_postmaster_with_a_550_without_asking_the_backend
    connect do |socket|
      socket.gets
      command socket, "HELO test.client.example"
      command socket, "MAIL FROM:<sender@example.com>"

      [ "Postmaster", "POSTMASTER", "postmaster" ].each do |recipient|
        assert_match(/\A550/, command(socket, "RCPT TO:<#{recipient}>"), "expected 550 for #{recipient}")
      end
    end

    assert_empty @backend.calls.select { |call| call.first == :route }
  end

  # Some forwarding services' locals exceed RFC 5321's 64-octet ceiling; a 501 would bounce their forwards.
  def test_accepts_a_forwarding_sender_whose_local_part_exceeds_64_octets
    forwarder = "jane.doe.forwarding.mailbox+caf_=everyone=one.example@gmail.com"

    deliver(to: "everyone@one.example", from: forwarder)

    assert_equal forwarder, sole(@backend.stored)[:envelope].mail_from
  end

  def test_stores_8_bit_message_bytes_exactly_as_sent
    body = "Caf\xC3\xA9 \xF0\x9F\x93\xAB in eight-bit octets".b

    connect do |socket|
      read_smtp_response(socket)
      socket.write "EHLO client.example\r\n"
      read_smtp_lines(socket)
      command socket, "MAIL FROM:<sender@example.com> BODY=8BITMIME"
      command socket, "RCPT TO:<everyone@one.example>"
      command socket, "DATA"
      command socket, "Subject: Hi\r\n\r\n#{body}\r\n.".b
    end

    assert_includes sole(@backend.stored)[:raw].b, body
  end

  private
    def start_listener(**overrides)
      start(MailGate::MxListener, backend: @backend, hostname: "mx.test", max_message_size: 10_000, max_recipients: 50,
        max_processings: 2, max_connections: 10, max_connections_per_ip: 10, max_messages_per_ip: nil,
        max_tls_sessions_per_ip: nil, stress_threshold: nil, **overrides)
    end

    def open_data
      socket = Socket.tcp("127.0.0.1", @port)
      socket.gets
      [ "HELO test.client.example", "MAIL FROM:<sender@example.com>", "RCPT TO:<everyone@one.example>" ].each do |line|
        command socket, line
      end
      [ socket, command(socket, "DATA") ]
    end

    def deliver(to:, from: "sender@example.com", raw: RAW, helo: "test.client.example")
      smtp = Net::SMTP.new("127.0.0.1", @port)
      smtp.disable_starttls
      smtp.start(helo) { smtp.send_message(raw, from, to) }
    end

    def sole(records)
      assert_equal 1, records.size
      records.first
    end

    def received_header(helo:, remote_ip:)
      session = MailGate::Session.new
      session.helo = helo
      session.remote_ip = remote_ip
      @listener.send(:received_header, session)
    end
end
