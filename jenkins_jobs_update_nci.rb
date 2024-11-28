#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-FileCopyrightText: 2015-2020 Harald Sitter <sitter@kde.org>
# SPDX-License-Identifier: LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL

# To only update some jobs run locally with e.g.
# PANGEA_FACTORIZE_ONLY='keurocalc' NO_UPDATE=1 UPDATE_INCLUDE='_keurocalc' ./jenkins_jobs_update_nci.rb

require 'sigdump/setup'

require_relative 'lib/nci'
require_relative 'lib/projects/factory'
require_relative 'lib/jenkins/project_updater'
require_relative 'lib/kdeproject_component'

Dir.glob(File.expand_path('jenkins-jobs/*.rb', __dir__)).each do |file|
  require file
end

Dir.glob(File.expand_path('jenkins-jobs/nci/*.rb', __dir__)).each do |file|
  require file
end

# Updates Jenkins Projects
class ProjectUpdater < Jenkins::ProjectUpdater
  def initialize
    @job_queue = Queue.new
    @flavor = 'nci'
    @blacklisted_plugins = [
      'ircbot', # spammy drain on performance
      'instant-messaging' # dep of ircbot and otherwise useless
    ]
    @projects_dir = "#{__dir__}/data/projects"
    JenkinsJob.flavor_dir = "#{__dir__}/jenkins-jobs/#{@flavor}"
    super
  end

  private

  def jobs_without_template
    # FIXME: openqa is temporary while this is still being set up.
    JenkinsApi::Client.new.view.list_jobs('testy 🧪') +
      JenkinsApi::Client.new.job.list('^test_.*') +
      %w[a_extra-cmake-modules] # This is a multibranch pipe, a view itself.
  end

  # Append nci templates to list.
  def all_template_files
    files = super
    files + Dir.glob("#{JenkinsJob.flavor_dir}/templates/**.xml.erb")
  end

  def load_overrides!
    # TODO: there probably should be a conflict check so they don't override
    # the same thing.
    files = Dir.glob("#{__dir__}/data/projects/overrides/nci-*.yaml")
    raise 'No overrides found?' if files.empty?

    CI::Overrides.default_files += files
  end

  def populate_queue
    load_overrides!

    all_meta_builds = []
    all_mergers = []
    type_projects = {}

    NCI.types.each do |type|
      projects_file = "#{@projects_dir}/nci/#{type}.yaml"
      projects = ProjectsFactory.from_file(projects_file,
                                           branch: "Neon/#{type}")

      type_projects[type] = projects

      next unless type == 'unstable'

      projects.each do |project|
        branch = project.packaging_scm.branch
        branches = NCI.types.collect do |t|
          # We have Neon/type and Neon/type_series if a branch is only
          # applicable to a specific series.
          ["Neon/#{t}"] + NCI.series.collect { |s, _| "Neon/#{t}_#{s}" }
        end.flatten
        branches << 'master'
        next unless branch&.start_with?(*branches)

        # FIXME: this is fairly hackish
        dependees = []
        # Mergers need to be upstreams to the build jobs otherwise the
        # build jobs can trigger before the merge is done (e.g. when)
        # there was an upstream change resulting in pointless build
        # cycles.
        NCI.series.each_key do |series|
          NCI.types.each do |type_for_dependee|
            dependees << BuilderJobBuilder.basename(series,
                                                    type_for_dependee,
                                                    project.component,
                                                    project.name)
          end
        end
        all_mergers << enqueue(NCIMergerJob.new(project,
                                                dependees: dependees,
                                                branches: branches))
      # end of projects.each
      end
    # end of nci.types
    end

    watchers = {}
    NCI.series.each_key do |distribution|
      NCI.types.each do |type|
        all_builds = [] # Tracks all builds in this type.

        type_projects[type].each do |project|
          if !project.series_restrictions.empty? &&
             !project.series_restrictions.include?(distribution)
            warn "#{project.name} has been restricted to" \
                 " #{project.series_restrictions}." \
                 " We'll not create a job for #{distribution}."
            next
          end

          # enable ARM for all releases
          project_architectures = if type == 'unstable' ||
                                      type == 'stable' ||
                                      type == 'release' ||
                                      type == 'experimental'
                                    NCI.all_architectures
                                  else
                                    NCI.architectures
                                  end
          jobs = ProjectJob.job(project,
                                distribution: distribution,
                                type: type,
                                architectures: project_architectures)

          jobs.each { |j| enqueue(j) }
          all_builds += jobs

          # FIXME: presently not forcing release versions of things we have a
          #   stable for
          next unless type == 'release'
          next unless distribution == NCI.current_series ||
                      (NCI.future_series && distribution == NCI.future_series)
          # Projects without upstream scm are native and don't need watching.
          next unless project.upstream_scm
          # Do not watch !uscan. They'll not be able to produce anything
          # worthwhile.
          # TODO: should maybe assert that all release builds are either git
          #   or uscan? otherwise we may have trouble with not getting updates
          next unless project.upstream_scm.type == 'uscan'
          # TODO: this is a bit of a crutch it may be wiser to actually
          #   pass the branch as param into watcher.rb and have it make
          #   sense of it (requires some changes to the what-needs-merging
          #   logic first)
          # FIXME: the crutch is also a fair bit unreliable. if a repo doesn't
          #   have a release branch (which is technically possible - e.g.
          #   ubuntu-release-upgrader only has a single branch) then the watcher
          #   coverage will be lacking.
          next unless %w[Neon/release].any? do |x|
            x == project.packaging_scm&.branch
          end

          watcher = WatcherJob.new(project)
          next if watchers.key?(watcher.job_name) # Already have one.

          watchers[watcher.job_name] = watcher
        end # end of type_projects[type].each

        next if type == NCI.qt_stage_type

        # Meta builders.
        all_builds.select! { |j| j.is_a?(ProjectJob) }
        meta_builder = MetaBuildJob.new(type: type,
                                        distribution: distribution,
                                        downstream_jobs: all_builds)

        # Legacy distros deserve no daily builds. Only manual ones. So, do
        # not put them in the regular meta list and thus prevent progenitor from
        # even knowing about them.
        if distribution != NCI.old_series
          all_meta_builds << enqueue(meta_builder)
        end

        enqueue(DailyPromoteJob.new(type: type,
                                    distribution: distribution,
                                    dependees: [meta_builder]))

        enqueue(I386InstallCheckJob.new(type: type,
                                        distribution: distribution,
                                        dependees: [meta_builder]))

        enqueue(MGMTRepoTestVersionsJob.new(type: type,
                                            distribution: distribution))

        enqueue(MGTMCNFJob.new(type: type, dist: distribution))

        if (NCI.future_series && NCI.future_series == distribution) ||
           (NCI.current_series && NCI.old_series == distribution)
          enqueue(MGMTRepoTestVersionsUpgradeJob.new(type: type,
                                                     distribution: distribution))
        end
      end # end of NCI.types.each

      # amd 64 ISO's && docker's
      NCI.architectures.each do |architecture|
        standard_args = {
          imagename: 'neon',
          distribution: distribution,
          architecture: architecture,
          metapackage: 'neon-desktop'
        }.freeze
        is_future = distribution == NCI.future_series

        # unstable edition iso stuff's
        dev_unstable_isoargs = standard_args.merge(
          type: 'unstable',
          neonarchive: 'unstable',
          cronjob: 'H H * * 0'
        )
        # unstable edition docker stuff's
        dev_unstable_dockerargs = dev_unstable_isoargs.merge(
          is_future: is_future
        )
        enqueue(NeonIsoJob.new(**dev_unstable_isoargs))
        enqueue(NeonDockerJob.new(**dev_unstable_dockerargs))

        # Only make unstable ISO for the next series while in early mode.
        next if distribution == NCI.future_series && NCI.future_is_early

        # ko unstable edition iso stuff's
        ko_dev_unstable_isoargs = standard_args.merge(
          type: 'ko',
          neonarchive: 'unstable',
          cronjob: 'H H * * 5',
          metapackage: 'neon-desktop-ko'
        )
        enqueue(NeonIsoJob.new(**ko_dev_unstable_isoargs))

        # mobile unstable edition iso stuff's
        mobile_dev_unstable_isoargs = standard_args.merge(
          type: 'mobile',
          neonarchive: 'unstable',
          cronjob: 'H H * * 0',
          metapackage: 'plasma-phone'
        )
        enqueue(NeonIsoJob.new(**mobile_dev_unstable_isoargs))

        # developer unstable edition iso stuff's
        dev_unstable_dev_isoargs = standard_args.merge(
          type: 'developer',
          neonarchive: 'unstable',
          cronjob: 'H H * * 1'
        )
        # unstable developer edition docker stuff's
        dev_unstable_dev_dockerargs = dev_unstable_dev_isoargs.merge(
          is_future: is_future
        )
        enqueue(NeonIsoJob.new(**dev_unstable_dev_isoargs))
        enqueue(NeonDockerJob.new(**dev_unstable_dev_dockerargs))

        # stable edition iso stuff's
        dev_stable_isoargs = standard_args.merge(
          type: 'stable',
          neonarchive: 'stable',
          cronjob: 'H H * * 2'
        )
        enqueue(NeonIsoJob.new(**dev_stable_isoargs))

        # testing edition iso stuff's
        dev_testing_isoargs = standard_args.merge(
          type: 'testing',
          neonarchive: 'testing',
          cronjob: 'H H * * 2'
        )
        # testing edition docker stuff's
        dev_testing_dockerargs = dev_testing_isoargs.merge(
          is_future: is_future
        )
        enqueue(NeonIsoJob.new(**dev_testing_isoargs))
        enqueue(NeonDockerJob.new(**dev_testing_dockerargs))

        # ko testing edition iso stuff's
        ko_dev_testing_isoargs = standard_args.merge(
          type: 'ko',
          neonarchive: 'testing',
          cronjob: 'H H * * 5',
          metapackage: 'neon-desktop-ko'
        )
        enqueue(NeonIsoJob.new(**ko_dev_testing_isoargs))

        # mobile testing edition iso stuff's
        mobile_dev_testing_isoargs = standard_args.merge(
          type: 'mobile',
          neonarchive: 'testing',
          cronjob: 'H H * * 0',
          metapackage: 'plasma-phone'
        )
        enqueue(NeonIsoJob.new(**mobile_dev_testing_isoargs))

        # release edition iso stuff's
        release_release_isoargs = standard_args.merge(
          type: 'release',
          neonarchive: 'release',
          cronjob: 'H H * * 3'
        )
        enqueue(NeonIsoJob.new(**release_release_isoargs))

        # user edition iso stuff's
        user_release_isoargs = standard_args.merge(
          type: 'user',
          neonarchive: is_future ? 'release' : 'user',
          cronjob: 'H H * * 4'
        )
        user_release_dockerargs = user_release_isoargs.merge(
          is_future: is_future
        )
        enqueue(NeonIsoJob.new(**user_release_isoargs))
        enqueue(NeonDockerJob.new(**user_release_dockerargs))

        # ko user edition iso stuff's
        ko_user_release_isoargs = standard_args.merge(
          type: 'ko',
          neonarchive: 'user',
          cronjob: 'H H * * 5',
          metapackage: 'neon-desktop-ko'
        )
        enqueue(NeonIsoJob.new(**ko_user_release_isoargs))

        # mobile user edition iso stuff's
        mobile_user_release_isoargs = standard_args.merge(
          type: 'mobile',
          neonarchive: 'user',
          cronjob: 'H H * * 0',
          metapackage: 'plasma-phone'
        )
        enqueue(NeonIsoJob.new(**mobile_user_release_isoargs))
      end # endo of NCI.architectures.each

      # arm64 ISO's, docker's and img's
      NCI.extra_architectures.each do |architecture|
        standard_args = {
          imagename: 'neon-arm64',
          distribution: distribution,
          architecture: architecture,
          metapackage: 'neon-desktop'
        }.freeze
        is_future = distribution == NCI.future_series

        # only arm64 unstable until we can actually produce an iso
        dev_unstable_isoargs = standard_args.merge(
          type: 'unstable',
          neonarchive: 'unstable',
          cronjob: 'H H * * 0'
        )
        enqueue(NeonIsoJob.new(**dev_unstable_isoargs))

        # old bitrotted arm images
        dev_unstable_imgargs = { type: 'devedition-gitunstable',
                                distribution: distribution,
                                architecture: 'arm64',
                                metapackage: 'neon-desktop',
                                imagename: 'neon',
                                neonarchive: 'dev/unstable',
                                cronjob: 'H H * * 0' }
        enqueue(NeonImgJob.new(**dev_unstable_imgargs))

        user_imgargs = { type: 'useredition',
                        distribution: distribution,
                        architecture: 'arm64',
                        metapackage: 'neon-desktop',
                        imagename: 'neon',
                        neonarchive: 'user',
                        cronjob: 'H H * * 0'}
        enqueue(NeonImgJob.new(**user_imgargs))
      end # end of NCI.extra_architectures.each

      enqueue(MGMTRepoDivert.new(target: "unstable_#{distribution}"))
      enqueue(MGMTRepoUndoDivert.new(target: "unstable_#{distribution}"))
      enqueue(MGMTAppstreamUbuntuFilter.new(dist: distribution))
    end # end of NCI.series.each_key

    ## META jobs
    # Watchers is a hash, only grab the actual jobs and enqueue them.
    watchers.each_value { |w| enqueue(w) }
    merger = enqueue(MetaMergeJob.new(downstream_jobs: all_mergers))
    progenitor = enqueue(
      MgmtProgenitorJob.new(downstream_jobs: all_meta_builds,
                            blockables: [merger])
    )
    enqueue(MGMTPauseIntegrationJob.new(downstreams: [progenitor]))
    enqueue(MGMTAptlyJob.new(dependees: [progenitor]))

    ## MGMT jobs
    jeweller = enqueue(MGMTGitJewellerJob.new)
    enqueue(MGMTMergerDebianFrameworks.new)
    enqueue(MGMTDigitalOcean.new)
    enqueue(MGMTDigitalOceanDangler.new)
    enqueue(MGMTDockerEphemerals.new)
    enqueue(MGMTGitSemaphoreJob.new)
    enqueue(MGMTDockerPersistents.new)
    enqueue(MGMTDockerPersistentsCleanup.new)
    enqueue(MGMTDockerPersistentsDailyCleanup.new)
    enqueue(MGMTJenkinsJobScorer.new)
    enqueue(MGMTJenkinsPruneParameterListJob.new)
    enqueue(MGMTJenkinsPruneOld.new)
    enqueue(MGMTJobUpdater.new)
    enqueue(MGMTRepoCleanupJob.new)
    enqueue(MGMTRepoMetadataCheck.new(dependees: []))
    enqueue(MGMTSeedDeploy.new)
    enqueue(MGMTToolingJob.new(downstreams: [], dependees: []))
    enqueue(MGMTToolingPersistents.new)
    enqueue(MGMTToolingEphemerals.new)
    enqueue(MGMTToolingUpdateSubmodules.new)
    enqueue(MGMTWorkspaceCleanerJob.new(dist: NCI.current_series))

    ## Q&A jobs
    # This QA is only run for user edition, otherwise we'd end up in a nightmare
    # of which component is available in which edition but not the other.
    enqueue(MGMTAppstreamComponentsDuplicatesJob.new(type: 'user',
                                                     dist: NCI.current_series))

    # FIXME: this is hardcoded because we don't have a central map between
    #   'type' and repo path, additionally doing this programatically would
    #   require querying the aptly api. it's unclear if this is worthwhile.
    enqueue(MGMTAppstreamGenerator.new(repo: 'unstable',
                                       type: 'unstable',
                                       dist: NCI.current_series))
    enqueue(MGMTAppstreamGenerator.new(repo: 'stable',
                                       type: 'stable',
                                       dist: NCI.current_series))
    enqueue(MGMTAppstreamGenerator.new(repo: 'testing',
                                       type: 'testing',
                                       dist: NCI.current_series))
    enqueue(MGMTAppstreamGenerator.new(repo: 'release',
                                       type: 'release',
                                       dist: NCI.current_series))
    enqueue(MGMTAppstreamGenerator.new(repo: 'user',
                                       type: 'user',
                                       dist: NCI.current_series))
    # Note for the future: when introducing a future_series it's probably wise
    # to split the job and asgen.rb for the new series. That way its easy to
    # drop legacy support when the time comes. At the time of writing both
    # things are highly coupled to their series, so treating them as something
    # generic is folly.
    enqueue(MGMTAppstreamHealthJob.new(dist: NCI.current_series))
    if NCI.future_series
      # Add generator jobs as necessary here. Probably sound to start out
      # with unstable first though.
      enqueue(MGMTAppstreamHealthJob.new(dist: NCI.future_series))
      enqueue(MGMTAppstreamGenerator.new(repo: 'unstable',
                                         type: 'unstable',
                                         dist: NCI.future_series))
    end

    # In addition to type-dependent cnf jobs we create one for user edition itself. user repo isn't a type but
    # we want cnf data all the same. Limited to current series for no particular reason other than convenience (future
    # doesn't necessarily have a user repo right out the gate).
    # The data comes from release becuase they are similar enough and iterating Snapshots is hugely different so
    # adding support for them to cnf_generate is a drag.
    enqueue(MGTMCNFJob.new(type: 'release', dist: NCI.current_series, conten_push_repo_dir: 'user', name: 'user'))

    enqueue(MGMTSnapshotUser.new(dist: NCI.current_series, origin: 'release', target: 'user'))
    enqueue(MGMTSnapshotTesting.new(dist: NCI.current_series, origin: 'stable', target: 'testing'))
    if NCI.future_series
      enqueue(MGMTSnapshotUser.new(dist: NCI.future_series, origin: 'release', target: 'user'))
      enqueue(MGMTSnapshotTesting.new(dist: NCI.future_series, origin: 'stable', target: 'testing'))
    end

    enqueue(MGMTVersionListJob.new(dist: NCI.current_series, type: 'user', notify: true))
    enqueue(MGMTVersionListJob.new(dist: NCI.current_series, type: 'release'))
    enqueue(MGMTVersionListJob.new(dist: NCI.current_series, type: 'testing'))
    enqueue(MGMTVersionListJob.new(dist: NCI.current_series, type: 'stable'))
    enqueue(MGMTVersionListJob.new(dist: NCI.current_series, type: 'unstable'))
    if NCI.future_series
      enqueue(MGMTVersionListJob.new(dist: NCI.future_series, type: 'user', notify: true))
      enqueue(MGMTVersionListJob.new(dist: NCI.future_series, type: 'release'))
      enqueue(MGMTVersionListJob.new(dist: NCI.future_series, type: 'testing'))
      enqueue(MGMTVersionListJob.new(dist: NCI.future_series, type: 'stable'))
      enqueue(MGMTVersionListJob.new(dist: NCI.future_series, type: 'unstable'))
    end

    enqueue(MGMTFwupdCheckJob.new(dist: NCI.current_series, type: 'user', notify: true))
    enqueue(MGMTFwupdCheckJob.new(dist: NCI.current_series, type: 'testing'))
    if NCI.future_series
      enqueue(MGMTFwupdCheckJob.new(dist: NCI.future_series, type: 'user', notify: true))
      enqueue(MGMTFwupdCheckJob.new(dist: NCI.future_series, type: 'testing'))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  updater = ProjectUpdater.new
  updater.update
  updater.install_plugins
end
