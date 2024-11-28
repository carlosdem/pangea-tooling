#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Copyright (C) 2016-2018 Harald Sitter <sitter@kde.org>
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

require 'aptly'
require 'date'
require 'optparse'

require_relative 'lib/repo_diff'

require_relative '../lib/jenkins'
require_relative '../lib/aptly-ext/remote'
require_relative '../lib/pangea/mail'

DIST = ENV.fetch('DIST')
prefix = 'testing'
repo = 'stable'

def send_email(mail_text, prefix)
  puts 'sending notification mail'
  Pangea::SMTP.start do |smtp|
    mail = <<-MAIL
From: Neon CI <noreply@kde.org>
To: neon-notifications@kde.org
Subject: #{prefix} Snapshot Done

#{mail_text}
    MAIL
    smtp.send_message(mail,
                      'no-reply@kde.org',
                      'neon-notifications@kde.org')
  end
end

Faraday.default_connection_options =
  Faraday::ConnectionOptions.new(request: {timeout: 15 * 60})

# SSH tunnel so we can talk to the repo
Aptly::Ext::Remote.neon do
  mail_text = ''
  differ = RepoDiff.new
  diff_rows = differ.diff_repo('stable', 'testing', DIST)
  diff_rows.each do |name, architecture, new_version, old_version|
    mail_text += name.ljust(20) + architecture.ljust(10) + new_version.ljust(40) + old_version.ljust(40) + "\n"
  end
  puts 'Repo Diff:'
  puts mail_text

  stamp = Time.now.utc.strftime('%Y%m%d.%H%M')
  release = Aptly::Repository.get("#{repo}_#{DIST}")
  snapshot = release.snapshot(Name: "#{repo}_#{DIST}-#{stamp}")
  # Limit to user for now.
  pubs = Aptly::PublishedRepository.list.select do |x|
    x.Prefix == prefix.to_s && x.Distribution == DIST
  end
  pub = pubs[0]
  pub.update!(Snapshots: [{ Name: snapshot.Name, Component: 'main' }])

  published_snapshots = Aptly::PublishedRepository.list.select do |x|
    x.SourceKind == 'snapshot'
  end
  published_snapshots = published_snapshots.map(&:Sources).flatten.map(&:Name)
  puts "Currently published snapshots: #{published_snapshots}"

  snapshots = Aptly::Snapshot.list.select do |x|
    x.Name.start_with?(release.Name)
  end
  puts "Available snapshots: #{snapshots.map(&:Name)}"

  dangling_snapshots = snapshots.reject do |x|
    published_snapshots.include?(x.Name)
  end
  dangling_snapshots.each do |x|
    x.CreatedAt = DateTime.parse(x.CreatedAt)
  end
  dangling_snapshots.sort_by!(&:CreatedAt)
  dangling_snapshots.pop # Pop newest dangle as a backup.
  puts "Dangling snapshots: #{dangling_snapshots.map(&:Name)}"
  dangling_snapshots.each(&:delete)
  puts 'Dangling snapshots deleted'
  send_email(mail_text, prefix)
end
