require "test_helper"

class MailGate::MxScoringTest < MailGate::ListenerTestCase
  RAW = "Authentication-Results: mx.test; dkim=pass\r\nSubject: Hi\r\n\r\nBody.\r\n"

  Verdict = Data.define(:action, :score, :smtp_reply) do
    def initialize(smtp_reply: nil, **) = super
  end

  Reply = Data.define(:code, :enhanced, :text)

  class FakeScorer
    attr_accessor :verdict, :failure
    attr_reader :checks

    def initialize
      @checks = []
    end

    def check(raw, envelope, budget:)
      @checks << { raw:, envelope:, budget: }
      raise @failure if @failure

      @verdict
    end
  end

  def setup
    @backend = MailGate::FakeBackend.new
    @backend.routes = { "one@one.example" => :one, "two@two.example" => :two }
    @scorer = FakeScorer.new
    @scorer.verdict = Verdict.new(action: :no_action, score: 0.5)
    start_listener
  end

  def test_scores_once_for_every_recipient_and_hands_the_verdict_to_each_store
    deliver

    check = @scorer.checks.first
    assert_equal 1, @scorer.checks.size
    assert_equal 8, check[:budget]
    assert_equal %w[ one@one.example two@two.example ], check[:envelope].rcpt_to
    assert_equal [ check[:raw] ], @backend.stored.map { |stored| stored[:raw] }.uniq
    assert_equal [ @scorer.verdict ] * 2, @backend.stored.map { |stored| stored[:verdict] }
  end

  def test_scores_with_the_envelope_the_backend_stores_hostname_and_queue_id_included
    deliver

    envelope = @scorer.checks.first[:envelope]
    assert_equal "unknown", envelope.hostname
    assert_match(/\A[A-Z0-9]{12}\z/, envelope.queue_id)
    assert_equal [ envelope ] * 2, @backend.stored.map { |stored| stored[:envelope] }
  end

  def test_scores_the_message_with_inbound_authentication_results_already_stripped
    deliver

    refute_includes @scorer.checks.first[:raw], "dkim=pass"
  end

  def test_stores_a_message_to_mark_with_its_verdict
    [ :add_header, :rewrite_subject ].each do |action|
      @scorer.verdict = Verdict.new(action:, score: 7)
      deliver
    end

    assert_equal [ :add_header, :add_header, :rewrite_subject, :rewrite_subject ],
      @backend.stored.map { |stored| stored[:verdict].action }
  end

  def test_answers_a_soft_reject_with_a_451_and_stores_nothing
    @scorer.verdict = Verdict.new(action: :soft_reject, score: 4)

    error = assert_raises(Net::SMTPServerBusy) { deliver }

    assert_match "451 4.7.1", error.message
    assert_empty @backend.stored
  end

  def test_answers_a_reject_with_a_554_and_stores_nothing
    @scorer.verdict = Verdict.new(action: :reject, score: 15)

    error = assert_raises(Net::SMTPFatalError) { deliver }

    assert_match "554 5.7.1", error.message
    assert_empty @backend.stored
  end

  def test_answers_with_the_scorers_reply_when_it_is_well_formed
    @scorer.verdict = Verdict.new(action: :soft_reject, score: 4, smtp_reply: Reply.new(450, "4.7.1", "Greylisted, try again later"))
    error = assert_raises(Net::SMTPServerBusy) { deliver }
    assert_equal "450 4.7.1 Greylisted, try again later", error.message.chomp

    @scorer.verdict = Verdict.new(action: :reject, score: 15, smtp_reply: Reply.new("550", "5.7.350", "Message looks like spam"))
    error = assert_raises(Net::SMTPFatalError) { deliver }
    assert_equal "550 5.7.350 Message looks like spam", error.message.chomp

    assert_empty @backend.stored
  end

  def test_falls_back_to_its_own_reply_when_the_scorers_is_malformed
    [ Reply.new(554, "5.7.1", "Spam\r\n250 2.0.0 OK"), Reply.new(250, "2.0.0", "OK"), Reply.new(554, "4.7.1", "Spam"),
      Reply.new(554, "5.7", "Spam"), Reply.new(554, "5.7.1", "Spam\nmore"), Reply.new(554, "5.7.1", "x" * 201),
      Reply.new(554, "5.7.1", "Spam \u00e9"), Reply.new(554, "5.7.1", "") ].each do |reply|
      @scorer.verdict = Verdict.new(action: :reject, score: 15, smtp_reply: reply)
      error = assert_raises(Net::SMTPFatalError, reply.inspect) { deliver }
      assert_equal "554 5.7.1 Spam message rejected", error.message.chomp, reply.inspect
    end

    @scorer.verdict = Verdict.new(action: :soft_reject, score: 4, smtp_reply: Reply.new(554, "5.7.1", "Spam"))
    error = assert_raises(Net::SMTPServerBusy) { deliver }
    assert_equal "451 4.7.1 Try again later", error.message.chomp

    assert_empty @backend.stored
  end

  def test_stores_unscored_mail_when_the_backend_lets_it_through
    @scorer.failure = IOError.new("unreachable")

    deliver

    assert_equal [ [ :unscored, @scorer.failure ] ], @backend.calls.select { |call| call.first == :unscored }
    assert_equal [ nil, nil ], @backend.stored.map { |stored| stored[:verdict] }
  end

  def test_refuses_unscored_mail_when_the_backend_says_so
    @scorer.failure = IOError.new("unreachable")
    @backend.refusal = MailSmtp::LocalError.new("unscored")

    error = assert_raises(Net::SMTPServerBusy) { deliver }

    assert_match "451", error.message
    assert_empty @backend.stored
  end

  def test_requires_a_scan_budget_with_a_scorer
    assert_raises(MailGate::ConfigurationError) { restart_listener(scan_budget: nil) }
  end

  private
    def start_listener(**overrides)
      start(MailGate::MxListener, backend: @backend, scorer: @scorer, scan_budget: 8, hostname: "mx.test",
        max_message_size: 10_000, max_recipients: 50, max_processings: 2, max_connections: 10, max_connections_per_ip: 10,
        max_messages_per_ip: nil, max_tls_sessions_per_ip: nil, stress_threshold: nil, **overrides)
    end

    def deliver
      smtp = Net::SMTP.new("127.0.0.1", @port)
      smtp.disable_starttls
      smtp.start("test.client.example") { smtp.send_message(RAW, "sender@example.com", %w[ one@one.example two@two.example ]) }
    end
end
