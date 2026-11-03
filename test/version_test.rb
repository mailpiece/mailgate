require "test_helper"

class MailGate::VersionTest < MailGate::TestCase
  def test_the_version_is_a_release_number
    assert_match(/\A\d+\.\d+\.\d+\z/, MailGate::VERSION)
  end
end
