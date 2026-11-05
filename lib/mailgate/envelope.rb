module MailGate
  Envelope = Data.define(:ip, :hostname, :helo, :mail_from, :rcpt_to, :tls_version, :tls_cipher, :queue_id,
    :reverse_dns_status) do
    def initialize(reverse_dns_status: nil, **)
      super
    end
  end
end
