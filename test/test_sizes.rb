# frozen_string_literal: true
# test/test_sizes.rb
require 'test_helper'
require 'vmctl/sizes'

class TestSizes < Minitest::Test
  def test_parse_units
    assert_equal 1024, VMCtl::Sizes.parse('1K')
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse('20G')
    assert_equal 100 * 1024**4, VMCtl::Sizes.parse('100T')
    assert_equal 512 * 1024**2, VMCtl::Sizes.parse('512M')
  end

  def test_parse_plain_bytes
    assert_equal 1048576, VMCtl::Sizes.parse('1048576')
  end

  def test_parse_is_case_insensitive
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse('20g')
  end

  def test_parse_rejects_garbage
    assert_raises(ArgumentError) { VMCtl::Sizes.parse('notasize') }
    assert_raises(ArgumentError) { VMCtl::Sizes.parse('') }
  end

  def test_human_exact_units
    assert_equal '20G', VMCtl::Sizes.human(20 * 1024**3)
    assert_equal '512M', VMCtl::Sizes.human(512 * 1024**2)
    assert_equal '1K', VMCtl::Sizes.human(1024)
  end

  def test_human_non_divisible_falls_back_to_bytes
    assert_equal '1000', VMCtl::Sizes.human(1000)
    assert_equal '0', VMCtl::Sizes.human(0)
  end

  def test_round_trip
    assert_equal 20 * 1024**3, VMCtl::Sizes.parse(VMCtl::Sizes.human(20 * 1024**3))
  end
end
