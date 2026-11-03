require "test_helper"
require "timeout"

class MailGate::AuthenticationResultsTest < MailGate::TestCase
  RAW = <<~RAW.gsub("\n", "\r\n")
    DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=sender.example;
      s=default; h=from:to:subject; bh=abc123; b=def456
    From: Sender <person@sender.example>
    To: list@relay.example
    Subject: Hello

    Body.
  RAW

  def test_strips_a_header_claiming_our_own_authserv_id
    forged = "Authentication-Results: relay.example; spf=pass smtp.mailfrom=attacker@evil.example\r\n#{RAW}"

    stripped = MailGate::AuthenticationResults.strip(forged)

    refute_includes stripped, "attacker@evil.example"
    assert_includes stripped, "DKIM-Signature: v=1;"
    assert stripped.end_with?("\r\n\r\nBody.\r\n")
  end

  def test_strips_every_inbound_header_whatever_its_authserv_id_comment_colon_or_fold
    [
      "Authentication-Results: relay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results: someone-elses-relay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results: (legit) relay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results : relay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results:\r\n\trelay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results: RELAY.EXAMPLE; dkim=pass header.d=trusted.example",
      "Authentication-Results\r\n : relay.example; dkim=pass header.d=trusted.example",
      "Authentication-Results\r\n\t:\r\n relay.example; dkim=pass header.d=trusted.example",
      "aUTHENTICATION-rESULTS\r\n\t: relay.example; dkim=pass header.d=trusted.example"
    ].each do |forged|
      stripped = MailGate::AuthenticationResults.strip("#{forged}\r\n#{RAW}")

      refute_includes stripped, "trusted.example", "failed to strip: #{forged.inspect}"
    end
  end

  def test_strips_a_received_spf_however_it_is_folded
    [
      "Received-SPF: pass (relay.example: domain of trusted.example designates 192.0.2.1 as permitted sender)",
      "received-spf\r\n : pass client-ip=192.0.2.1; envelope-from=ceo@trusted.example"
    ].each do |forged|
      stripped = MailGate::AuthenticationResults.strip("#{forged}\r\n#{RAW}")

      refute_includes stripped, "trusted.example", "failed to strip: #{forged.inspect}"
    end
  end

  def test_keeps_arc_authentication_results_for_arc_verification
    arc = "ARC-Authentication-Results: i=1; forwarder.example; spf=pass\r\n#{RAW}"

    assert_equal arc, MailGate::AuthenticationResults.strip(arc)
  end

  def test_leaves_an_authentication_results_line_in_the_body
    raw = "Subject: Quoted\r\n\r\nAuthentication-Results: quoted.example; dkim=pass\r\n"

    assert_equal raw, MailGate::AuthenticationResults.strip(raw)
  end

  def test_hands_back_a_message_with_nothing_to_strip_without_copying_its_body
    message = "Subject: Big\r\n\r\n#{"a\r\n" * 1_000_000}"

    assert MailGate::AuthenticationResults.strip(message).equal?(message), "copied the message"
  end

  def test_never_splits_the_body_into_lines
    message = "Authentication-Results: relay.example; dkim=pass\r\nSubject: Big\r\n\r\n#{"a\r\n" * 300_000}"

    allocated = GC.stat(:total_allocated_objects)
    stripped = MailGate::AuthenticationResults.strip(message)

    assert_operator GC.stat(:total_allocated_objects) - allocated, :<, 100
    assert stripped == message.delete_prefix("Authentication-Results: relay.example; dkim=pass\r\n"), "stripped the wrong bytes"
  end

  def test_refuses_a_header_section_past_its_cap
    error = assert_raises(MailGate::Errors::HeaderSectionTooLarge) do
      MailGate::AuthenticationResults.strip("a\r\n" * 3_400_000)
    end

    assert_match(/\A552 5\.3\.4 /, error.response)
  end

  def test_strips_deeply_nested_parens_cheaply
    nested = "#{"(" * 50_000}#{")" * 50_000}"
    pathological = "Authentication-Results: #{nested} relay.example; dkim=pass header.d=trusted.example"

    stripped = Timeout.timeout(5) { MailGate::AuthenticationResults.strip("#{pathological}\r\n#{RAW}") }

    refute_includes stripped, "trusted.example"
  end
end
