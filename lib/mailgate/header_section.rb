module MailGate
  # The header section of a message as received, read without touching the body. mailsmtp refuses a bare CR or LF
  # in DATA, so every line ends in CRLF.
  class HeaderSection
    # Past a few hundred KB a header section is an attack on the parsers after us, not mail.
    MAX_BYTES = 256 * 1024

    attr_reader :bytesize

    def initialize(message)
      @message = message
      @bytesize = bytesize_of(message)

      raise Errors::HeaderSectionTooLarge, "Header section over #{MAX_BYTES} bytes" if bytesize > MAX_BYTES
    end

    # Each field as sent, with its folds and CRLF.
    def fields
      @fields ||= @message.byteslice(0, bytesize).lines.each_with_object([]) do |line, fields|
        if fields.any? && line.start_with?(" ", "\t")
          fields.last << line
        else
          fields << line
        end
      end
    end

    # A fold may sit anywhere, even between a field's name and its colon.
    def unfolded_fields
      fields.map { |field| field.gsub(/\r\n(?=[ \t])/, "") }
    end

    # The message without the fields that match +pattern+ once unfolded, or the message itself when none does.
    def without(pattern)
      kept = fields.zip(unfolded_fields).filter_map { |field, unfolded| field unless unfolded.match?(pattern) }

      if kept.size == fields.size
        @message
      else
        kept.join + @message.byteslice(bytesize, @message.bytesize - bytesize)
      end
    end

    private
      # Through the last field's CRLF: none when the message opens with the empty line, all of it when there is none.
      def bytesize_of(message)
        if message.start_with?("\r\n")
          0
        elsif separator = message.byteindex("\r\n\r\n")
          separator + 2
        else
          message.bytesize
        end
      end
  end
end
