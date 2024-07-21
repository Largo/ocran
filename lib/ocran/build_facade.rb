# frozen_string_literal: true

module Ocran
  class BuildFacade
    def initialize(filer, launcher)
      @filer, @launcher = filer, launcher
    end

    def mkdir(...) = @filer.__send__(__method__, ...)

    def cp(...) = @filer.__send__(__method__, ...)

    def export(...) = @launcher.__send__(__method__, ...)

    def exec(...) = @launcher.__send__(__method__, ...)
  end
end
