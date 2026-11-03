module MailGate
  Envelope = Data.define(:ip, :hostname, :helo, :mail_from, :rcpt_to, :tls_version, :tls_cipher, :queue_id)
end
