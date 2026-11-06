require "ipaddr"
require "mailresolver"

module MailGate
  # Forward-confirmed reverse DNS for a client: the PTR name, only when it resolves back to the IP.
  # Looked up on its own thread, which may outlive its connection: each query gets mailresolver's timeouts cut to what
  # is left of the timeout, so the thread ends by then on its own, and +slots+ caps how many run at once.
  class ReverseDns
    UNKNOWN = "unknown"
    HOSTNAME = /\A(?=.{1,253}\z)[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9])?)*\z/
    # A full host name, dotted, with no underscore: the only unconfirmed name worth handing a scorer.
    FQDN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

    # +outcome+ is :verified, :not_found, :unconfirmed, :temporary_failure, :timeout, :error, or :busy when every slot
    # was taken.
    # +duration+ is the seconds the lookup took.
    # +unconfirmed_name+ is the PTR name that did not resolve back, when a full host name, which the client chose:
    # never trust it.
    Result = Data.define(:name, :outcome, :error, :duration, :unconfirmed_name) do
      def initialize(unconfirmed_name: nil, **)
        super
      end
    end

    # No time left for another query, or the client is gone.
    Expired = Class.new(StandardError)
    private_constant :Expired

    # +resolver+ replaces mailresolver, used as it is; nil builds one for each query.
    def initialize(resolver, ip, timeout:, slots: nil)
      @resolver = resolver
      @ip = ip
      @started = monotonic_time
      @deadline = @started + timeout
      @cancelled = false

      if slots.nil? || slots.claim
        @thread = Thread.new do
          lookup
        ensure
          slots&.release
        end
        @thread.report_on_exception = false
      else
        @result = Result.new(UNKNOWN, :busy, nil, 0)
      end
    end

    # Waits for the lookup, but never past the timeout from connect.
    def result
      @result ||= finished_result
    end

    # Starts no further query; the one in flight ends within its own timeouts.
    def cancel
      @cancelled = true
    end

    private
      def finished_result
        if @thread.join([ @deadline - monotonic_time, 0 ].max)
          @thread.value
        else
          cancel
          Result.new(UNKNOWN, :timeout, nil, @deadline - @started)
        end
      end

      def lookup
        address = IPAddr.new(@ip).native
        name = query(:ptr, address.to_s).first.to_s.downcase.chomp(".")

        if !name.match?(HOSTNAME)
          finished(UNKNOWN, :unconfirmed)
        elsif resolves_to?(name, address)
          finished(name, :verified)
        else
          finished(UNKNOWN, :unconfirmed, unconfirmed_name: (name if name.match?(FQDN)))
        end
      rescue MailResolver::NotFound, IPAddr::Error
        finished(UNKNOWN, :not_found)
      rescue Expired
        finished(UNKNOWN, :timeout)
      rescue MailResolver::ServerFailure, MailResolver::Timeout => error
        finished(UNKNOWN, :temporary_failure, error)
      rescue StandardError => error
        finished(UNKNOWN, :error, error)
      end

      # Only the client's own family: an IPv4 client is confirmed by an A record alone.
      def resolves_to?(name, address)
        query(address.ipv4? ? :a : :aaaa, name).any? { |forward| IPAddr.new(forward).native == address }
      rescue MailResolver::NotFound
        false
      end

      def query(type, name)
        remaining = @deadline - monotonic_time
        raise Expired if @cancelled || remaining <= 0

        (@resolver || resolver_within(remaining)).public_send(type, name)
      end

      def resolver_within(remaining)
        MailResolver::Resolver.new(timeouts: timeouts_within(remaining))
      end

      # mailresolver's schedule, scaled down to fit.
      def timeouts_within(remaining)
        scale = [ remaining / MailResolver::Resolver::TIMEOUTS.sum, 1 ].min
        MailResolver::Resolver::TIMEOUTS.map { it * scale }
      end

      def finished(name, outcome, error = nil, unconfirmed_name: nil)
        Result.new(name, outcome, error, monotonic_time - @started, unconfirmed_name)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
  end
end
