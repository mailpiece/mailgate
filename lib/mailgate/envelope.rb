module MailGate
  Envelope = Data.define(:ip, :hostname, :helo, :mail_from, :rcpt_to, :tls_version, :tls_cipher, :queue_id,
    :reverse_dns_status, :unconfirmed_hostname) do
    def initialize(reverse_dns_status: nil, unconfirmed_hostname: nil, **)
      super
    end
  end
end
