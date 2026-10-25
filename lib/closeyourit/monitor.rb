# frozen_string_literal: true

require_relative "instrumenter"

module CloseYourIt
  # Macro to instrument a method automatically:
  #
  #   class Report
  #     include CloseYourIt::Monitor
  #     def generate(...) = ...
  #     monitor :generate
  #   end
  #
  # Wraps the method via `Module#prepend` timing it, without changing its signature/result.
  module Monitor
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def monitor(method_name, label: nil)
        wrapper = Module.new do
          define_method(method_name) do |*args, **kwargs, &block|
            measured_label = label || "#{self.class}##{method_name}"
            CloseYourIt::Instrumenter.measure(measured_label, args: args, kwargs: kwargs) do
              super(*args, **kwargs, &block)
            end
          end
        end
        prepend(wrapper)
      end
    end
  end
end
