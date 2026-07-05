# frozen_string_literal: true
# lib/vmctl/allocator.rb
require 'digest'

module VMCtl
  # Owns "what's the next free ID" decisions. Pure logic over the inventory.
  class Allocator
    # Locally-administered, unicast OUI base (second-least-significant bit of
    # the first octet set, least-significant clear): 0x5a = 0101_1010.
    OUI = [0x5a, 0x9c, 0xfc].freeze

    def initialize(config)
      @config = config
    end

    def next_link
      base = @config.defaults.link_base
      n = base
      n += 1 while link_taken?(n)
      n
    end

    def link_taken?(n)
      @config.vms.values.any? { |vm| vm.link == n }
    end

    def name_taken?(name)
      @config.vms.key?(name)
    end

    # Deterministic per-(name, index) MAC in the locally-administered range.
    # index 0 is the VM's primary NIC (unchanged); nonzero indexes are additional
    # NICs, seeded distinctly so a VM's NICs never share a generated MAC.
    def generate_mac(name, index = 0)
      seed = index.zero? ? name : "#{name}:nic#{index}"
      digest = Digest::SHA256.hexdigest(seed)
      tail = [digest[0, 2], digest[2, 2], digest[4, 2]].map { |h| h.to_i(16) }
      (OUI + tail).map { |b| format('%02x', b) }.join(':')
    end
  end
end
