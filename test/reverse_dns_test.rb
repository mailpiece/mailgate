require "test_helper"

class MailGate::ReverseDnsTest < MailGate::TestCase
  FakeResolver = MailResolver::Testing::FakeResolver

  # Answers each query after a delay, recording the thread it ran on.
  class SlowResolver < FakeResolver
    attr_reader :threads

    def initialize(zone, delay:)
      super(zone)
      @delay = delay
      @threads = Queue.new
    end

    def ptr(address)
      @threads << Thread.current
      sleep @delay
      super
    end

    def a(name)
      sleep @delay
      super
    end
  end

  # The default path, aimed at a nameserver that never answers, recording each query's timeouts and thread.
  class SilentReverseDns < MailGate::ReverseDns
    attr_reader :timeouts, :threads

    def initialize(nameserver, ip, timeout:)
      @nameserver = nameserver
      @timeouts = Queue.new
      @threads = Queue.new
      super(nil, ip, timeout:)
    end

    private
      def resolver_within(remaining)
        @threads << Thread.current
        @timeouts << timeouts_within(remaining)
        @nameserver.resolver(timeouts: timeouts_within(remaining))
      end
  end

  SLOW_ZONE = { "192.0.2.1" => { ptr: [ "slow.example" ] }, "slow.example" => { a: [ "192.0.2.1" ] } }.freeze

  def setup
    @nameserver = MailResolver::Testing::LocalNameserver.new(nil)
  end

  def teardown
    @nameserver.close
  end

  def test_names_a_client_whose_ptr_resolves_back_to_it
    resolver = FakeResolver.new("192.0.2.1" => { ptr: [ "Mail.Example.COM." ] }, "mail.example.com" => { a: [ "192.0.2.1" ] })

    assert_equal [ "mail.example.com", :verified ], outcome(resolver, "192.0.2.1")
  end

  def test_confirms_an_ipv6_client_whatever_form_its_address_takes
    resolver = FakeResolver.new("2001:db8::1" => { ptr: [ "v6.example" ] }, "v6.example" => { aaaa: [ "2001:0db8:0:0::1" ] })

    assert_equal [ "v6.example", :verified ], outcome(resolver, "2001:db8::1")
  end

  def test_looks_up_an_ipv4_mapped_client_as_ipv4
    resolver = FakeResolver.new("192.0.2.1" => { ptr: [ "mail.example.com" ] }, "mail.example.com" => { a: [ "192.0.2.1" ] })

    assert_equal [ "mail.example.com", :verified ], outcome(resolver, "::ffff:192.0.2.1")
  end

  def test_is_unknown_without_a_ptr
    assert_equal [ "unknown", :not_found ], outcome(FakeResolver.new, "192.0.2.1")
    assert_equal [ "unknown", :not_found ], outcome(FakeResolver.new, "not an ip")
  end

  def test_is_unknown_when_the_name_does_not_resolve_back
    resolver = FakeResolver.new("192.0.2.1" => { ptr: [ "forged.example" ] }, "forged.example" => { a: [ "198.51.100.7" ] },
      "192.0.2.2" => { ptr: [ "gone.example" ] },
      "192.0.2.3" => { ptr: [ "bad name (x [1.2.3.4])" ] })

    assert_equal [ "unknown", :unconfirmed ], outcome(resolver, "192.0.2.1")
    assert_equal [ "unknown", :unconfirmed ], outcome(resolver, "192.0.2.2")
    assert_equal [ "unknown", :unconfirmed ], outcome(resolver, "192.0.2.3")
  end

  def test_is_unknown_on_a_temporary_failure_but_says_so
    resolver = FakeResolver.new("192.0.2.1" => { ptr: :servfail }, "192.0.2.2" => { ptr: :timeout },
      "192.0.2.3" => { ptr: [ "flaky.example" ] }, "flaky.example" => { a: :servfail })

    %w[ 192.0.2.1 192.0.2.2 192.0.2.3 ].each do |ip|
      result = MailGate::ReverseDns.new(resolver, ip, timeout: 1).result
      assert_equal [ "unknown", :temporary_failure ], [ result.name, result.outcome ], ip
      assert_kind_of MailResolver::Error, result.error
    end
  end

  def test_is_unknown_when_the_resolver_itself_breaks
    resolver = Object.new
    def resolver.ptr(_) = raise(NoMethodError, "boom")

    result = MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 1).result

    assert_equal [ "unknown", :error ], [ result.name, result.outcome ]
    assert_equal "boom", result.error.message
  end

  def test_bounds_a_nameserver_that_never_answers_by_the_timeout
    reverse_dns = SilentReverseDns.new(@nameserver, "192.0.2.1", timeout: 0.4)
    thread = reverse_dns.threads.pop

    started = monotonic_time
    assert_equal :timeout, reverse_dns.result.outcome
    assert_operator monotonic_time - started, :<, 0.5
    assert thread.join(0.5), "lookup thread outlived its timeout"
    assert_in_delta 0.4, reverse_dns.timeouts.pop.sum, 0.05
  end

  def test_ends_its_own_thread_at_the_timeout_even_when_nobody_asks
    reverse_dns = SilentReverseDns.new(@nameserver, "192.0.2.1", timeout: 0.4)

    assert reverse_dns.threads.pop.join(0.9), "lookup thread outlived its timeout"
  end

  def test_uses_a_slow_answer_that_arrives_in_time
    result = MailGate::ReverseDns.new(SlowResolver.new(SLOW_ZONE, delay: 0.2), "192.0.2.1", timeout: 1).result

    assert_equal [ "slow.example", :verified ], [ result.name, result.outcome ]
    assert_in_delta 0.4, result.duration, 0.15
  end

  def test_starts_no_query_past_the_timeout
    resolver = SlowResolver.new(SLOW_ZONE, delay: 0.3)
    reverse_dns = MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 0.2)
    thread = resolver.threads.pop

    assert_equal :timeout, reverse_dns.result.outcome
    assert thread.join(0.5)
    assert_equal [ [ "192.0.2.1", :ptr ] ], resolver.queries
  end

  def test_cancel_starts_no_further_query_and_leaves_no_thread_behind
    resolver = SlowResolver.new(SLOW_ZONE, delay: 0.2)
    reverse_dns = MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 30)
    thread = resolver.threads.pop

    reverse_dns.cancel

    assert thread.join(0.5), "lookup thread survived cancel"
    assert_equal [ [ "192.0.2.1", :ptr ] ], resolver.queries
  end

  def test_is_unknown_without_a_thread_while_every_lookup_slot_is_taken
    slots = MailGate::Slots.new(1)
    resolver = SlowResolver.new(SLOW_ZONE, delay: 0.3)
    first = MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 1, slots:)
    resolver.threads.pop

    second = MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 1, slots:)

    assert_equal [ "unknown", :busy ], [ second.result.name, second.result.outcome ]
    assert_equal :verified, first.result.outcome
    assert_equal :verified, MailGate::ReverseDns.new(resolver, "192.0.2.1", timeout: 1, slots:).result.outcome
  end

  private
    def outcome(resolver, ip)
      result = MailGate::ReverseDns.new(resolver, ip, timeout: 1).result
      [ result.name, result.outcome ]
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
