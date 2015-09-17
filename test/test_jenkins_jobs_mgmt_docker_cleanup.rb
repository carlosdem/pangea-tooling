require 'vcr'
require_relative '../jenkins-jobs/mgmt-docker-cleanup.rb'
require_relative '../ci-tooling/test/lib/testcase'

class MGMTDockerCleanupTest < TestCase
  def setup
    VCR.configure do |config|
      config.cassette_library_dir = @datadir
      config.hook_into :excon
      config.default_cassette_options = {
        match_requests_on:  [:method, :uri, :body]
      }
    end
  end
  def test_render
    r = MGMTDockerCleanupJob.new(arch: 'arch')
    assert_equal(File.read("#{@datadir}/test_render.xml"), r.render_template)
  end

  def test_cleanup_on_new
    VCR.use_cassette(__method__) do
      assert_nothing_raised do
        require_relative '../mgmt/docker_cleanup.rb'
      end
    end
  end
end
