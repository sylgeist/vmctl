# frozen_string_literal: true
# lib/vmctl/sizes.rb
module VMCtl
  # Parse/format disk sizes using 1024-based units (matching truncate(1)).
  module Sizes
    UNITS = { 'K' => 1024, 'M' => 1024**2, 'G' => 1024**3, 'T' => 1024**4 }.freeze
    ORDERED = [['T', 1024**4], ['G', 1024**3], ['M', 1024**2], ['K', 1024]].freeze

    def self.parse(str)
      m = /\A(\d+)([KMGT]?)\z/i.match(str.to_s)
      raise ArgumentError, "invalid size: #{str.inspect}" unless m
      n = m[1].to_i
      suffix = m[2].upcase
      suffix.empty? ? n : n * UNITS.fetch(suffix)
    end

    def self.human(bytes)
      return '0' if bytes.zero?
      ORDERED.each do |suffix, factor|
        return "#{bytes / factor}#{suffix}" if (bytes % factor).zero?
      end
      bytes.to_s
    end
  end
end
