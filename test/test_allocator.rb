# frozen_string_literal: true
# test/test_allocator.rb
require 'test_helper'
require 'vmctl/config'
require 'vmctl/allocator'

class TestAllocator < Minitest::Test
  def config_with(links)
    raw = {
      'defaults' => { 'link_base' => 10 },
      'vms' => links.each_with_object({}) do |l, acc|
        acc["vm#{l}"] = { 'network' => 'n', 'link' => l, 'disks' => [] }
      end
    }
    VMCtl::Config.new(raw)
  end

  def test_first_link_is_link_base_when_empty
    alloc = VMCtl::Allocator.new(config_with([]))
    assert_equal 10, alloc.next_link
  end

  def test_skips_taken_links
    alloc = VMCtl::Allocator.new(config_with([10, 11, 13]))
    assert_equal 12, alloc.next_link
  end

  def test_returns_next_after_contiguous_block
    alloc = VMCtl::Allocator.new(config_with([10, 11, 12]))
    assert_equal 13, alloc.next_link
  end

  def test_ignores_links_below_base
    alloc = VMCtl::Allocator.new(config_with([3, 10]))
    assert_equal 11, alloc.next_link
  end

  def test_link_taken
    alloc = VMCtl::Allocator.new(config_with([10]))
    assert alloc.link_taken?(10)
    refute alloc.link_taken?(11)
  end

  def test_name_taken
    alloc = VMCtl::Allocator.new(config_with([10]))
    assert alloc.name_taken?('vm10')
    refute alloc.name_taken?('pod99')
  end

  def test_generate_mac_is_locally_administered_and_deterministic
    alloc = VMCtl::Allocator.new(config_with([]))
    mac = alloc.generate_mac('pod34')
    assert_match(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/, mac)
    first_octet = mac.split(':').first.to_i(16)
    assert_equal 0b10, first_octet & 0b11, "must be locally-administered unicast"
    assert_equal mac, alloc.generate_mac('pod34'), "must be deterministic"
    refute_equal mac, alloc.generate_mac('pod35')
  end
end
