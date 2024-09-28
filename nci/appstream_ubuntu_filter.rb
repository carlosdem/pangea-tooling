#!/usr/bin/env ruby

# frozen_string_literal: true

# SPDX-FileCopyrightText: 2020 Harald Sitter <sitter@kde.org>
# SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL

# This mighty script auto generates an exclusion list of ubuntu provided
# appstream components that we do not want to have in discover. We don't support
# third party applications  coming form ubuntu. The ideal way to use third
# party software is through bundle tech such as flatpak/snap/appimage.
# NOTE: at the time of writing removal only applies to lower scored appstream
# sources (i.e. ubuntu) but leaves the source that applies the score (i.e. neon)
# unaffected. This allows us to simply take a list of all ubuntu components
# we want removed without having to take special care of the component
# appearing in neon as well. Should this change we'll stop seeing KDE software
# in discover pretty much (I doubt it will change though).

require 'json'
require 'tty/command'

require_relative '../lib/apt'
require_relative 'lib/setup_repo'

Component = Struct.new(:id, :kind)

DIST = ENV.fetch('DIST')
TARGET_DIR = "#{DIST}/main"

Dir.chdir(TARGET_DIR) # fails if the dir is missing for whatever reason

unless File.exist?('/usr/bin/appstreamcli')
  Apt::Get.install('appstream')
  Apt::Get.update # refresh appstream cache!
end

# DO NOT SETUP NEON REPOS. We need the ubuntu list only, we always want to
# see our stuff, so adding neon repos would only make things slower for
# no good reason.

ID_PATTERN_PREFIX = 'Identifier:'
ID_PATTERN = /#{ID_PATTERN_PREFIX} (?<id>[^\s]+) \[(?<kind>.+)\]/.freeze
NULLCMD = TTY::Command.new(printer: :null)

out, _err = NULLCMD.run('appstreamcli', 'search', '*')

components = []
out.each_line do |line|
  next unless line.start_with?(ID_PATTERN_PREFIX)

  match = ID_PATTERN.match(line)
  raise "Expected match on: #{line}" unless match

  components << Component.new(match[:id], match[:kind])
end
raise 'No components found, something is wrong!' if components.empty?

filter_components = components.select do |comp|
  case comp.kind
  when 'desktop-app'
    true
  when 'unknown', 'generic', 'console-app', 'web-app', 'service', 'addon',
      'runtime', 'font', 'codec', 'input-method', , 'operating_system',
      'firmware', 'driver', 'localization', 'repository', 'icon-theme'
    # NOTE: addons do not appear in discover on their own, so there is no
    #   point in filtering them. Worse yet, filtering them means the packages
    #   themselves will show up with shitty metadata.
    # TODO: should we really leave web-applications?
    # <struct Component id="im.riot.webapp", kind="web-application">
    # <struct Component id="io.devdocs.webapp", kind="web-application">
    false
  else
    # The explicit listing is primarily there so we have to look at every
    # possible type and decide whether we want to keep it or not.
    # When an unexpected kind is found you'll want to figure out if it is
    # reasonable portable to keep around or should be filtered out.
    raise "Unexpected component kind #{comp}"
  end
end

# --- JSON Seralization Dance ---
# We keep the auto removed components in a second json file, this serves no
# purpose other than letting us tell whether a human added a component to
# the removal list or the script. By extension we'll not fiddle with
# components added by a human.

auto_removed_components = []
if File.exist?('auto-removed-components.json')
  auto_removed_components = JSON.parse(File.read('auto-removed-components.json'))
end
removed_components = JSON.parse(File.read('removed-components.json'))
manually_removed_components = removed_components - auto_removed_components

filter_components = filter_components.collect(&:id)
removed_components = (manually_removed_components + filter_components)

File.write('auto-removed-components.json',
           JSON.generate(filter_components.uniq.compact.sort) + "\n")

File.write('removed-components.json',
           JSON.pretty_generate(removed_components.uniq.compact.sort) + "\n")
