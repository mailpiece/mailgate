module MailGate
  # Records every call; each answer is an attribute a test sets.
  class FakeBackend
    attr_writer :tls
    attr_accessor :storage_full, :routes, :tokens, :senders, :inactive, :rate_limited, :refusal
    attr_reader :calls, :errors, :stored, :submitted

    def initialize
      @tls = Tls::TEST_CONTEXT
      @storage_full = false
      @routes = {}
      @tokens = {}
      @senders = {}
      @inactive = false
      @rate_limited = false
      @calls = []
      @errors = []
      @stored = []
      @submitted = []
    end

    def tls
      @tls.is_a?(Exception) ? raise(@tls) : @tls
    end

    def report_error(error)
      @errors << error
    end

    def storage_full?
      called :storage_full?
      @storage_full
    end

    def route(address)
      called :route, address
      route = @routes[address.downcase]
      route.is_a?(Exception) ? raise(route) : route
    end

    def store(route, **message)
      called :store, route
      @stored << message.merge(route:)
    end

    def unscored(error, envelope)
      called :unscored, error
      raise @refusal if @refusal
    end

    def authenticate(username, password, ip:)
      called :authenticate, username, password
      @tokens[password]
    end

    def may_send_as?(id, address)
      called :may_send_as?, id, address
      @senders.fetch(id, []).include?(address)
    end

    def account_active?(id)
      called :account_active?, id
      !@inactive
    end

    def rate_limited?(id)
      called :rate_limited?, id
      @rate_limited
    end

    def submit(id, **message)
      called :submit, id
      @submitted << message.merge(id:)
    end

    def fail_at(method, error)
      @failure_at = method
      @failure = error
    end

    private
      def called(*call)
        @calls << call
        raise @failure if @failure && call.first == @failure_at
      end
  end
end
