#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/ci/containment'

TOOLING_PATH = File.dirname(__dir__)
binds = [
  "#{TOOLING_PATH}:#{TOOLING_PATH}",
  "#{Dir.pwd}:#{Dir.pwd}",
  "/dev:/dev"
]

Docker.options[:read_timeout] = 4 * 60 * 60 # 4 hours.

DIST = ENV.fetch('DIST_RELEASE')

BUILD_TAG = ENV.fetch('BUILD_TAG')

c = CI::Containment.new(BUILD_TAG,
                        image: CI::PangeaImage.new(:debian, DIST),
                        privileged: true,
                        no_exit_handlers: false,
                        binds: binds)
status_code = c.run(Cmd: ARGV)
exit status_code
