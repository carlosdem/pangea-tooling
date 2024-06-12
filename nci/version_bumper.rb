#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-FileCopyrightText: 2023 Harald Sitter <sitter@kde.org>
# SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL

require_relative '../lib/debian/control'
require_relative '../lib/kdeproject_component'
require_relative '../lib/projects/factory/neon'

require 'awesome_print'
require 'deep_merge'
require 'tty/command'
require 'yaml'

# Iterates all kf6 repos and adjusts the packaging for the new kf6 version #.
class Mutagen
  attr_reader :cmd

  def initialize
    @cmd = TTY::Command.new
  end



  def run
    if File.exist?('kf6')
      Dir.chdir('kf6')
    else
      Dir.mkdir('kf6')
      Dir.chdir('kf6')
     end

    repos = ProjectsFactory::Neon.ls
    KDEProjectsComponent.kf6_jobs.uniq.each do |project|
      repo = repos.find { |x| x.end_with?("/#{project}") }

        p [project, repo]
          if File.exist?("#{project}")
            next
          else
            cmd.run('git', 'clone', "git@invent.kde.org:neon/#{repo}")
          end
        rescue
          next
        end
    #end

    Dir.glob('*') do |dir|
      next unless File.directory?(dir)

      p dir
      Dir.chdir(dir) do
        if cmd.run('git', 'log', '-1', '--format=%s') == 'new release 6.3.0'
          break
        else
        cmd.run('git', 'fetch', 'origin')
        #cmd.run('git', 'reset', '--hard')
        cmd.run('git', 'checkout', 'Neon/release_jammy')
        #cmd.run('git', 'reset', '--hard', 'origin/Neon/release')
        cmd.run('dch', '--force-bad-version', '--force-distribution', '--distribution', 'jammy', '--newversion', '6.3.0-0neon', 'new release')
        cmd.run('git', 'commit', '--all', '--message', 'new release 6.3.0') unless cmd.run!('git', 'diff', '--quiet').success?
        cmd.run('git', 'push')
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  Mutagen.new.run
end
