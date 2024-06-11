# frozen_string_literal: true

# SPDX-FileCopyrightText: 2014-2017 Harald Sitter <sitter@kde.org>
# SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL

require 'fileutils'
require 'logger'
require 'logger/colors'
require 'open3'
require 'tmpdir'

require_relative 'apt'
require_relative 'aptly-ext/filter'
require_relative 'dpkg'
require_relative 'repo_abstraction'
require_relative 'retry'
require_relative 'thread_pool'
require_relative 'ci/fake_package'

# Base class for install checks, isolating common logic.
class InstallCheckBase
  def initialize
    @log = Logger.new(STDOUT)
    @log.level = Logger::INFO
  end

  def run_test(candidate_ppa, target_ppa)
    # Make sure all repos under testing are removed first.
    target_ppa.remove
    candidate_ppa.remove

    # Add the present daily snapshot, install everything.
    # If this fails then the current snapshot is kaputsies....
    if target_ppa.add
      # Now install everything in the neon repo
      unless target_ppa.install
        @log.info 'daily failed to install.'
        daily_purged = target_ppa.purge
        unless daily_purged
          @log.info <<-INFO.tr($/, '')
daily failed to install and then failed to purge. Maybe check maintscripts?
          INFO
        end
      end
    end
    @log.unknown 'done with daily'

    # temporary while ddebs is broken
    FileUtils.rm('/etc/apt/sources.list.d/org.kde.neon.com.ubuntu.ddebs.list', force: true)
    # NOTE: If daily failed to install, no matter if we can upgrade live it is
    # an improvement just as long as it can be installed...
    # So we purged daily again, and even if that fails we try to install live
    # to see what happens. If live is ok we are good, otherwise we would fail
    # anyway

    Retry.retry_it(times: 5, sleep: 5) do
      raise unless candidate_ppa.add
      raise 'failed to update' unless Apt.update
    end
    unless candidate_ppa.install
      @log.error 'all is vain! live PPA is not installing!'
      exit 1
    end

    # All is lovely. Let's make sure all live packages uninstall again
    # (maintscripts!) and then start the promotion.
    unless candidate_ppa.purge
      @log.error <<-ERROR.tr($/, '')
live PPA installed just fine, but can not be uninstalled again. Maybe check
maintscripts?
      ERROR
      exit 1
    end

    @log.info "writing package list in #{Dir.pwd}"
    File.write('sources-list.json', JSON.generate(candidate_ppa.sources))
  end
end

# Kubuntu install check.
class InstallCheck < InstallCheckBase
  def install_fake_pkg(name)
    FakePackage.new(name).install
  end

  def run(candidate_ppa, target_ppa)
    if Process.uid.to_i.zero?
      # Disable invoke-rc.d because it is crap and causes useless failure on
      # install when it fails to detect upstart/systemd running and tries to
      # invoke a sysv script that does not exist.
      File.write('/usr/sbin/invoke-rc.d', "#!/bin/sh\n")
      # Speed up dpkg
      File.write('/etc/dpkg/dpkg.cfg.d/02apt-speedup', "force-unsafe-io\n")
      # Prevent xapian from slowing down the test.
      # Install a fake package to prevent it from installing and doing anything.
      # This does render it non-functional but since we do not require the
      # database anyway this is the apparently only way we can make sure
      # that it doesn't create its stupid database. The CI hosts have really
      # bad IO performance making a full index take more than half an hour.
      install_fake_pkg('apt-xapian-index')
      File.open('/usr/sbin/update-apt-xapian-index', 'w', 0o755) do |f|
        f.write("#!/bin/sh\n")
      end
      # Also install a fake resolvconf because docker is a piece of shit cunt
      # https://github.com/docker/docker/issues/1297
      install_fake_pkg('resolvconf')
      # Cryptsetup has a new release in jammy-updates but installing this breaks in docker
      install_fake_pkg('cryptsetup')
      # Disable manpage database updates
      Open3.popen3('debconf-set-selections') do |stdin, _stdo, stderr, wait_thr|
        stdin.puts('man-db man-db/auto-update boolean false')
        stdin.close
        wait_thr.join
        puts stderr.read
      end
      # Make sure everything is up-to-date.
      raise 'failed to update' unless Apt.update
      raise 'failed to dist upgrade' unless Apt.dist_upgrade
      # Install ubuntu-minmal first to make sure foundations nonsense isn't
      # going to make the test fail half way through.
      raise 'failed to install ubuntu-minimal' unless Apt.install('ubuntu-minimal')

      # Because dependencies are fucked
      # [14:27] <sitter> dictionaries-common is a crap package
      # [14:27] <sitter> it suggests a wordlist but doesn't pre-depend them or
      # anything, intead it just craps out if a wordlist provider is installed
      # but there is no wordlist -.-
      system('apt-get install wamerican') || raise
      # Hold base-files. If we get lsb_release switched mid-flight and things
      # break we are dead in the water as we might not have a working pyapt
      # setup anymore and thus can't edit the sources.list.d content.
      system('apt-mark hold base-files') || raise
    end

    run_test(candidate_ppa, target_ppa)
  end
end

# This overrides run behavior
class RootInstallCheck < InstallCheck
  # Override the core test which assumes a 'live' repo and a 'staging' repo.
  # Instead we have a proposed repo and a root.
  # The root is installed version-less. Then we upgrade to the proposed repo and
  # hope everything is awesome.
  def run_test(proposed, root)
    proposed.remove

    @log.info 'Installing root.'
    unless root.install
      @log.error 'Root failed to install!'
      raise
    end
    @log.info 'Done with root.'

    @log.info 'Installing proposed.'
    unless proposed.add
      @log.error 'Failed to add proposed repo.'
      raise
    end
    unless proposed.install
      @log.error 'all is vain! proposed is not installing!'
      raise
    end
    @log.info 'Install of proposed successful. Trying to purge.'
    unless proposed.purge
      @log.error 'Failed to purge the candidate!'
      raise
    end

    @log.info 'All good!'
  end
end
