#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL
# SPDX-FileCopyrightText: 2015 Rohan Garg <rohan@garg.io>
# SPDX-FileCopyrightText: 2015 Harald Sitter <sitter@kde.org>

require 'tty/command'

TTY::Command.new.run('sudo bash neon_i386_docker.sh', '--arch', 'i386', 'build_i386', 'jammy')
