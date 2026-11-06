require "test_helper"

class MailGate::ErrorsTest < MailGate::TestCase
  def test_a_configuration_error_is_still_an_argument_error
    assert_operator MailGate::ConfigurationError, :<, ArgumentError
  end

  def test_an_address_refusal_counts_as_a_failed_authentication
    assert_operator MailGate::Errors::AddressNotAllowed, :<, MailSmtp::AuthenticationFailed
    assert_equal "535 5.7.1 Authentication not accepted from this address", MailGate::Errors::AddressNotAllowed.new.response
  end

  def test_an_account_rate_limit_is_a_450_but_not_the_per_ip_limit
    assert_equal "450 4.7.1 Requested mail action not taken: too many messages, try again later", MailGate::Errors::RateLimited.new.response
    refute_operator MailGate::Errors::RateLimited, :<, MailSmtp::RateLimited
  end
end
