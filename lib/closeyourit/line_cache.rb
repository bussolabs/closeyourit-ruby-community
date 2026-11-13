# frozen_string_literal: true

module CloseYourIt
  # In-process cache of source file lines, for the frames' context lines
  # (pre_context/context_line/post_context). Bounded: beyond MAX_FILES only the entry inserted first
  # is evicted (FIFO: Hash keeps insertion order), so recently read files stay available. Unreadable
  # files are cached too (as nil) and not probed again. Thread-safe: the mutex guards only the lookup
  # and the store, never the disk read, so a slow read does not block other files. Two threads
  # missing on the same file may both read it (first time only); the store re-checks the key, so the
  # later one neither overwrites the entry nor evicts another file.
  module LineCache
    MAX_FILES = 200

    @cache = {}
    @mutex = Mutex.new

    class << self
      # The file's lines (chomped), or nil if unreadable or a synthetic path ("(eval)", "(irb)").
      def lines(path)
        return nil if path.nil? || path.empty? || path.start_with?("(")

        @mutex.synchronize { return @cache[path] if @cache.key?(path) }

        store(path, read_lines(path))
      end

      def clear
        @mutex.synchronize { @cache.clear }
      end

      private

      def store(path, lines)
        @mutex.synchronize do
          return @cache[path] if @cache.key?(path) # a concurrent read stored it first

          @cache.shift if @cache.size >= MAX_FILES
          @cache[path] = lines
        end
      end

      def read_lines(path)
        return nil unless File.readable?(path)

        File.readlines(path, chomp: true)
      rescue StandardError
        nil
      end
    end
  end
end
