# frozen_string_literal: true

module CloseYourIt
  module Rails
    # Application call site of a slow query (privacy-safe → always sent): first backtrace frame
    # cleaned by Rails.backtrace_cleaner (removes gems/framework, keeps app code), without the
    # ":in '...'" suffix. E.g. "app/models/order.rb:42".
    module QuerySource
      def self.from_caller(backtrace = caller)
        frame = ::Rails.backtrace_cleaner.clean(backtrace).first
        return nil if frame.nil?

        frame.split(":in ", 2).first
      end
    end
  end
end
