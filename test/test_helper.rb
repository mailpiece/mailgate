$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "mailgate"
require "socket"
require "net/smtp"
require "base64"
require "mailresolver/testing"

require_relative "support/fake_backend"
require_relative "support/tls"

module MailGate
  class TestCase < Minitest::Test
  end

  class ListenerTestCase < TestCase
    include Tls

    def teardown
      @listener&.stop
    end

    private
      def start(listener_class, **options)
        @port = free_port
        @listener = listener_class.new(host: "127.0.0.1", port: @port, logger: Logger.new(nil),
          resolver: MailResolver::Testing::FakeResolver.new, greet_wait: nil, **options).tap(&:start)
      end

      def restart_listener(**overrides)
        @listener.stop
        start_listener(**overrides)
      end

      def free_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end

      def connect
        Socket.tcp("127.0.0.1", @port) { |socket| yield socket }
      end

      def command(socket, line)
        socket.write "#{line}\r\n"
        socket.gets
      end

      def read_smtp_response(socket)
        loop do
          line = socket.gets
          break line if line.nil? || line[3] != "-"
        end
      end

      def read_smtp_lines(socket)
        [].tap do |lines|
          loop do
            line = socket.gets
            break if line.nil?
            lines << line.chomp
            break if line[3] != "-"
          end
        end
      end

      def starttls(socket)
        socket.write "STARTTLS\r\n"
        socket.gets
        OpenSSL::SSL::SSLSocket.new(socket, insecure_tls_context).tap(&:connect)
      end

      def insecure_tls_context
        OpenSSL::SSL::SSLContext.new.tap { |context| context.verify_mode = OpenSSL::SSL::VERIFY_NONE }
      end
  end
end
