# frozen_string_literal: true

module Ocran
  class RuntimeEnvironment
    class << self
      alias save new
    end

    attr_reader :env, :load_path, :pwd

    def initialize
      @env = ENV.to_hash.freeze
      @load_path = $LOAD_PATH.dup.freeze
      @pwd = Dir.pwd.freeze
    end
  end
end
