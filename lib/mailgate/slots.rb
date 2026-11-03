module MailGate
  # A cap shared across connection threads: how many slots each key holds, against one limit. A nil limit never refuses.
  class Slots
    def initialize(limit)
      @limit = limit
      @held = Hash.new(0)
      @mutex = Mutex.new
    end

    # Takes a slot for +key+, or answers false when it already holds the limit.
    def claim(key = nil)
      @mutex.synchronize do
        if @limit.nil? || @held[key] < @limit
          @held[key] += 1
          true
        else
          false
        end
      end
    end

    def release(key = nil)
      @mutex.synchronize do
        @held[key] -= 1
        @held.delete(key) unless @held[key].positive?
      end
    end
  end
end
