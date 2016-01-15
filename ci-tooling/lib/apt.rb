require 'logger'

# Cow powers!
#
# This module provides access to apt by catching method missing and passing the
# method call on to apt.
# So calling Apt.install will call 'apt install'. Also convenient default
# arguments will be injected into the call to give debugging and so forth.
#
# Commands that contain a hyphen are spelt with an underscore due to ruby
# langauge restrictions. All underscores are automatically replaced with hyphens
# upon method handling. To bypass this the Abstrapt.run method needs to be used
# directly.
module Apt
  # Represents a repository
  class Repository
    def initialize(name)
      @name = name
      self.class.send(:install_add_apt_repository)
    end

    # (see #add)
    def self.add(name)
      new(name).add
    end

    # Add Repository to sources.list
    def add
      args = []
      args << '-y'
      args << @name
      system('add-apt-repository', *args)
    end

    # (see #remove)
    def self.remove(name)
      new(name).remove
    end

    # Remove Repository from sources.list
    def remove
      args = []
      args << '-y'
      args << '-r'
      args << @name
      system('add-apt-repository', *args)
    end

    class << self
      private

      def install_add_apt_repository
        return if defined?(@add_apt_repository_installed)
        Apt.install('software-properties-common')
        @add_apt_repository_installed = true
      end

      def reset
        return unless defined?(@add_apt_repository_installed)
        remove_instance_variable(:@add_apt_repository_installed)
      end
    end
  end

  # Apt key management using apt-key binary
  class Key
    def self.method_missing(name, *caller_args)
      system('apt-key', name.to_s.gsub('_', '-'), *caller_args)
    end
  end

  def self.method_missing(name, *caller_args)
    Abstrapt.run('apt-get', name.to_s.gsub('_', '-'), *caller_args)
  end

  # More cow powers!
  # Calls apt-get instead of apt. Otherwise the same as {Apt}
  module Get
    def self.method_missing(name, *caller_args)
      Abstrapt.run('apt-get', name.to_s.gsub('_', '-'), *caller_args)
    end
  end

  private

  # Abstract base for apt execution.
  module Abstrapt
    def self.run(cmd, operation, *caller_args)
      @log ||= Logger.new(STDOUT)
      auto_update unless operation == 'update'
      run_internal(cmd, operation, *caller_args)
    end

    private

    def self.run_internal(cmd, operation, *caller_args)
      injection_args = []
      caller_args.delete_if do |arg|
        next false unless arg.is_a?(Hash)
        next false unless arg.key?(:args)
        injection_args = [*(arg[:args])]
        true
      end
      args = []
      args += default_args
      args += injection_args
      args << operation
      # Flatten args. system doesn't support nested arrays anyway, so flattening
      # is probably what the caller had in mind (e.g. install(['a', 'b']))
      args += [*caller_args].flatten
      @log.warn "APT run (#{cmd}, #{args})"
      system(cmd, *args)
    end

    def self.auto_update
      return unless @last_update.nil? || (Time.now - @last_update) >= (5 * 60)
      @last_update = Time.now
      Apt.update
    end

    # @return [Array<String>] default arguments to inject into apt call
    def self.default_args
      @default_args if defined?(@default_args)
      @default_args = []
      @default_args << '-y'
      @default_args << '-o' << 'APT::Get::force-yes=true'
      @default_args << '-o' << 'Debug::pkgProblemResolver=true'
      @default_args
    end

    def self.reset
      @last_update = nil
    end
  end
end
