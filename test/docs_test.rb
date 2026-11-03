require "test_helper"

# The README and the reference pages describe behavior, and these fail when a table there stops matching the code.
class MailGate::DocsTest < MailGate::TestCase
  ROOT = File.expand_path("..", __dir__)
  # Cells with no default of their own: an option the listener lacks, or one worked out from another.
  DERIVED = [ "—", "half of `max_processings`" ].freeze

  def test_the_event_table_lists_every_event
    documented = table("docs/instrument.md", "Event").map { |event, *| unquote(event).delete_prefix(":").to_sym }

    assert_equal MailGate::EVENTS.sort, documented.sort
  end

  def test_the_options_table_carries_each_listeners_defaults
    rows = table("README.md", "Option").flat_map do |options, *defaults, _|
      options.split(", ").map { |option| [ unquote(option).to_sym, defaults ] }
    end.to_h.except(:backend, :hostname)

    { 0 => MailGate::MxListener, 1 => MailGate::SubmissionListener }.each do |column, listener|
      documented = rows.filter_map { |option, defaults| [ option, value(defaults[column]) ] unless DERIVED.include?(defaults[column]) }.to_h

      assert_equal listener::DEFAULTS.sort.to_h, documented.sort.to_h, "#{listener} defaults"
    end
  end

  private
    def value(cell)
      case text = unquote(cell)
      when "nil" then nil
      when /\A"(.*)"\z/ then $1
      else Integer(text, exception: false) || Float(text)
      end
    end

    def unquote(cell)
      cell.delete_prefix("`").delete_suffix("`")
    end

    # The rows of the first table whose header starts with `first_header`.
    def table(page, first_header)
      lines = File.readlines(File.join(ROOT, page), chomp: true)
      header = lines.index { |line| line.start_with?("| #{first_header} |") }
      flunk "#{page} has no table headed #{first_header.inspect}" if header.nil?

      lines.drop(header + 2).take_while { |line| line.start_with?("|") }.map do |line|
        line.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)
      end
    end
end
