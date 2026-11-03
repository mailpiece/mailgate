require "openssl"

module MailGate
  module Tls
    class Context
      def initialize(cn)
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = OpenSSL::BN.rand(64)
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{cn}")
        cert.public_key = key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))

        @context = OpenSSL::SSL::SSLContext.new
        @context.cert = cert
        @context.key = key
      end

      def start(io)
        OpenSSL::SSL::SSLSocket.new(io, @context).tap { |ssl| ssl.sync_close = true }.tap(&:accept)
      end
    end

    TEST_CONTEXT = Context.new("mailgate.test")
  end
end
