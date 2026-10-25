# frozen_string_literal: true

module CloseYourIt
  # In-process cache of source file lines, for the frames' context lines
  # (pre_context/context_line/post_context). Bounded: beyond MAX_FILES it is emptied entirely —
  # simple and sufficient (the files of an app in error are few and recurring). Thread-safe.
  module LineCache
    MAX_FILES = 200

    @cache = {}
    @mutex = Mutex.new

    class << self
      # The file's lines (chomped), or nil if unreadable or a synthetic path ("(eval)", "(irb)").
      def lines(path)
        return nil if path.nil? || path.empty? || path.start_with?("(")

        @mutex.synchronize do
          return @cache[path] if @cache.key?(path)

          @cache.clear if @cache.size >= MAX_FILES
          @cache[path] = read_lines(path)
        end
      end

      def clear
        @mutex.synchronize { @cache.clear }
      end

      private

      def read_lines(path)
        return nil unless File.readable?(path)

        File.readlines(path, chomp: true)
      rescue StandardError
        nil
      end
    end
  end
end
