# frozen_string_literal: true
require_relative 'job'

class MGMTToolingNodes < JenkinsJob

  def initialize
    super('mgmt_tooling_nodes', 'mgmt_tooling_nodes.xml.erb')
  end
end
