# frozen_string_literal: true

module CloseYourIt
  # Bounded breadcrumb ring buffer. It lives in the Scope (one buffer per execution context),
  # written only by the owning thread → no mutex. Beyond `max_size` it drops the oldest.
  class BreadcrumbBuffer
    def initialize(max_size)
      @max_size = max_size.to_i
      @items = []
    end

    def add(breadcrumb)
      return self unless @max_size.positive?

      @items.shift while @items.size >= @max_size
      @items << breadcrumb
      self
    end

    def to_a
      @items.map(&:to_h)
    end

    def empty?
      @items.empty?
    end

    def size
      @items.size
    end
  end
end
