# frozen_string_literal: true
# test/test_substitution.rb
require 'test_helper'
require 'vmctl/substitution'

class TestSubstitution < Minitest::Test
  def test_replaces_known_tokens
    assert_equal 'a=1 b=2', VMCtl.substitute('a=%(x) b=%(y)', 'x' => '1', 'y' => '2')
  end

  def test_unknown_token_passes_through
    assert_equal 'keep %(z)', VMCtl.substitute('keep %(z)', 'x' => '1')
  end

  def test_tolerates_non_ascii_bytes
    out = VMCtl.substitute(+"# \xE2\x80\x94 %(x)\n".b, 'x' => 'ok')
    assert_includes out, 'ok'
  end
end
