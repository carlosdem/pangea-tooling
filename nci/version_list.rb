#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Copyright (C) 2019 Harald Sitter <sitter@kde.org>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) version 3, or any
# later version accepted by the membership of KDE e.V. (or its
# successor approved by the membership of KDE e.V.), which shall
# act as a proxy defined in Section 6 of version 3 of the license.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library.  If not, see <http://www.gnu.org/licenses/>.

require 'did_you_mean/spell_checker'
require 'erb'
require 'jenkins_junit_builder'
require 'net/sftp'

require_relative '../ci-tooling/lib/aptly-ext/filter'
require_relative '../ci-tooling/lib/aptly-ext/package'
require_relative '../lib/aptly-ext/remote'
require_relative 'version_list/violations'

S_IROTH = 0o4 # posix bitmask for world readable

DEBIAN_TO_KDE_NAMES = {
  'libkf5incidenceeditor' => 'incidenceeditor',
  'libkf5pimcommon' => 'pimcommon',
  'libkf5mailcommon' => 'mailcommon',
  'libkf5mailimporter' => 'mailimporter',
  'libkf5calendarsupport' => 'calendarsupport',
  'libkf5kmahjongg' => 'libkmahjongg',
  'libkf5grantleetheme' => 'grantleetheme',
  'libkf5libkleo' => 'libkleo',
  'libkf5libkdepim' => 'libkdepim',
  'libkf5eventviews' => 'eventviews',
  'libkf5sane' => 'libksane',
  'libkf5kexiv2' => 'libkexiv2',
  'kf5-kdepim-apps-libs' => 'kdepim-apps-libs',
  'libkf5ksieve' => 'libksieve',
  'libkf5gravatar' => 'libgravatar',
  'kf5-messagelib' => 'messagelib',
  'libkf5kgeomap' => 'libkgeomap',
  'libkf5kdcraw' => 'libkdcraw',
  'kde-spectacle' => 'spectacle',
  'libkf5kipi' => 'libkipi',

  # frameworks
  'kactivities-kf5' => 'kactivities',
  'kdnssd-kf5' => 'kdnssd',
  'kwallet-kf5' => 'kwallet',
  'baloo-kf5' => 'baloo',
  'ksyntax-highlighting' => 'syntax-highlighting',
  'attica-kf5' => 'attica',
  'prison-kf5' => 'prison',
  'kfilemetadata-kf5' => 'kfilemetadata',
  'kcalcore' => 'kcalendarcore',

  # plasma
  'plasma-discover' => 'discover'
}

# Sources that we do not package for some reason. Should be documented why!
BLACKLIST = [
  # Supposedly unmainatined which is why we opt to not maintain the entire
  # telepeathy stack.
  'ktp-contact-runner',
  'ktp-kded-module',
  'ktp-auth-handler',
  'ktp-approver',
  'ktp-desktop-applets',
  'ktp-accounts-kcm',
  'ktp-text-ui',
  'ktp-call-ui',
  'ktp-send-file',
  'ktp-common-internals',
  'ktp-contact-list',
  'ktp-filetransfer-handler',
  # Not actually useful for anything in production. It's a repo with tests.
  'plasma-tests'
]

# Maps "key" packages to a release scope. This way we can identify what version
# the given scope has in our repo.
KEY_MAPS = {
  'plasma-workspace' => 'Plasma by KDE',
  'kconfig' => 'KDE Frameworks',
  'okular' => 'KDE Applications'
}

key_file = ENV.fetch('SSH_KEY_FILE', nil)
ssh_args = key_file ? [{ keys: [key_file] }] : []

product_and_versions = []

# Publish ISO and associated content.
%w[release-service frameworks plasma].each do |scope|
  Net::SFTP.start('master.kde.org', 'ftpneon', *ssh_args) do |sftp|
    # delete old directories
    dir_path = "stable/#{scope}/"
    version_dirs = sftp.dir.glob(dir_path, '*')
    version_dirs = version_dirs.select(&:directory?)
    version_dirs = version_dirs.sort_by { |x| Gem::Version.new(x.name) }
    # lowest is first
    latest = version_dirs[-1]

    world_readable = ((latest.attributes.permissions & S_IROTH) == S_IROTH)
    unless world_readable
      warn "Version #{latest.name} of #{scope} not world readable!" \
           " This will mean that this scope's version isn't checked!"
      next
    end

    latest_path = "#{dir_path}/#{latest.name}/"
    tars = sftp.dir.glob(latest_path, '**/**')

    tars = tars.select { |x| x.name.include?('.tar.') }
    sig_ends = %w[.sig .asc]
    tars = tars.reject { |x| sig_ends.any? { |s| x.name.end_with?(s) } }

    product_and_versions += tars.collect do |tar|
      name = File.basename(tar.name) # strip possible subdirs
      match = name.match(/(?<product>[-\w]+)-(?<version>[\d\.]+)\.tar.+/)
      raise "Failed to parse #{name}" unless match

      [match[:product], match[:version]]
    end
  end
end

scoped_versions = {}
packaged_versions = {}
violations = []

Aptly::Ext::Remote.neon do
  pub = Aptly::PublishedRepository.list.find do |r|
    r.Prefix == 'user' && r.Distribution == 'bionic'
  end
  pub.Sources.each do |source|
    packages = source.packages(q: '$Architecture (source)')
    packages = packages.collect { |x| Aptly::Ext::Package::Key.from_string(x) }
    by_name = packages.group_by(&:name)

    # map debian names to kde names so we can easily compare things
    by_name = by_name.collect { |k, v| [DEBIAN_TO_KDE_NAMES.fetch(k, k), v] }.to_h

    # Hash the packages by their versions, take the versions and sort them
    # to get the latest available version of the specific package at hand.
    by_name = by_name.map do |name, pkgs|
      by_version = Aptly::Ext::LatestVersionFilter.debian_versions(pkgs)
      versions = by_version.keys
      [name, versions.max.upstream]
    end.to_h
    # by_name is now a hash of package names to upstream versions

    # Extract our scope markers into the output array with a fancy name.
    # This kind of collapses all plasma packages into one Plasma entry for
    # example.
    KEY_MAPS.each do |key_package, pretty_name|
      version = by_name[key_package]
      scoped_versions[pretty_name] = version
    end

    checker = DidYouMean::SpellChecker.new(dictionary: by_name.keys)
    product_and_versions.to_h.each do |remote_name, remote_version|
      next if BLACKLIST.include?(remote_name) # we don't package some stuff

      in_repo = by_name.include?(remote_name)
      unless in_repo
        corrections = checker.correct(remote_name)
        violations << MissingPackageViolation.new(remote_name, corrections)
        next
      end

      # Drop the entry from the packages hash. Since it is part of a scoped
      # release such as plasma it doesn't get listed separately in our
      # output hash.
      repo_version = by_name.delete(remote_name)
      if repo_version != remote_version
        violations <<
          WrongVersionViolation.new(remote_name, remote_version, repo_version)
        next
      end
    end

    packaged_versions = packaged_versions.merge(by_name)
  end
end

template = ERB.new(File.read("#{__dir__}/version_list/version_list.html.erb"))
html = template.result(OpenStruct.new(
  scoped_versions: scoped_versions,
  packaged_versions: packaged_versions
).instance_eval { binding })
File.write('versions.html', html)

if violations.empty?
  puts 'All OK!'
  exit 0
end
puts violations.join("\n")

suite = JenkinsJunitBuilder::Suite.new
suite.name = 'version_list'
suite.package = 'version_list'
violations.each do |violation|
  c = JenkinsJunitBuilder::Case.new
  c.name = violation.name
  c.time = 0
  c.classname = violation.class.to_s
  c.result = JenkinsJunitBuilder::Case::RESULT_FAILURE
  c.system_out.message = violation.to_s
  suite.add_case(c)
end
File.write('report.xml', suite.build_report)

exit 1 # had violations
