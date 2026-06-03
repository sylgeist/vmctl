# frozen_string_literal: true
# test/test_netgraph.rb
require 'test_helper'
require 'vmctl/netgraph'

class TestNetgraph < Minitest::Test
  def test_bridge_exists_true
    exec = FakeExecutor.new(probes: { 'ngctl info labs_vlan50:' => true })
    ng = VMCtl::Netgraph.new(exec)
    assert ng.bridge_exists?('labs_vlan50')
  end

  def test_bridge_exists_false
    exec = FakeExecutor.new(probes: { 'ngctl info nope:' => false })
    ng = VMCtl::Netgraph.new(exec)
    refute ng.bridge_exists?('nope')
  end

  def test_ensure_bridge_raises_with_helpful_message
    exec = FakeExecutor.new(probes: { 'ngctl info nope:' => false })
    ng = VMCtl::Netgraph.new(exec)
    err = assert_raises(VMCtl::NetgraphError) { ng.ensure_bridge!('nope') }
    assert_match(/nope/, err.message)
    assert_match(/netgraph_setup/, err.message)
  end

  def test_ensure_bridge_passes_when_present
    exec = FakeExecutor.new(probes: { 'ngctl info mgmt_vlan1:' => true })
    ng = VMCtl::Netgraph.new(exec)
    ng.ensure_bridge!('mgmt_vlan1') # must not raise
    assert ng.bridge_exists?('mgmt_vlan1')
  end
end
