require_relative "lib/mailgate/version"

Gem::Specification.new do |spec|
  spec.name = "mailgate"
  spec.version = MailGate::VERSION
  spec.platform = Gem::Platform::RUBY
  spec.required_ruby_version = ">= 3.4"
  spec.authors = [ "Simon Lev" ]

  spec.summary = "MX and submission listeners for mailsmtp."
  spec.description = "Receive mail on port 25 and take submissions on port 587 with the policy a mail service needs, and plug in your own storage, accounts and spam scorer."

  spec.homepage = "https://github.com/mailpiece/mailgate"
  spec.license = "MIT"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir[
    "lib/**/*.rb",
    "docs/**/*.md",
    "CHANGELOG.md",
    "README.md",
    "LICENSE",
    "mailgate.gemspec"
  ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "mailresolver"
  spec.add_dependency "mailsmtp"
end
