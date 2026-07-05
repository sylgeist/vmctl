# frozen_string_literal: true
# lib/vmctl/netgraph.rb
module VMCtl
  class NetgraphError < StandardError; end

  # Read-only view of netgraph. vmctl never mutates bridge topology — bridges
  # are host infrastructure created by the netgraph_setup rc script.
  class Netgraph
    def initialize(executor)
      @exec = executor
    end

    def bridge_exists?(name)
      @exec.success?('ngctl', 'info', "#{name}:")
    end

    def ensure_bridge!(name)
      return if bridge_exists?(name)
      raise NetgraphError,
            "bridge '#{name}' not found — is netgraph_setup running?"
    end
  end
end
