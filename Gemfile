source 'https://rubygems.org'

gem 'docker-api', '~> 1.23.0' # Container.refresh! only introduced in 1.23
gem 'git'
gem 'jenkins_api_client'
gem 'logger-colors'
gem 'oauth'
gem 'octokit'
gem 'git_clone_url'
gem 'uri-ssh_git', '~> 2.0'

group :development, :test do
  gem 'ci_reporter_test_unit',
      git: 'https://github.com/apachelogger/ci_reporter_test_unit',
      branch: 'test-unit-3'
  gem 'equivalent-xml'
  gem 'net-scp'
  gem 'rake'
  gem 'simplecov'
  gem 'simplecov-rcov'
  gem 'test-unit', '>= 3.0'
  gem 'rack'
  gem 'rubocop'
  gem 'rubocop-checkstyle_formatter'
  gem 'vcr', '~> 2'
  gem 'webmock'
  gem 'rake-notes'
  gem 'ruby-progressbar'
end

group :s3 do
  gem 'aws-sdk-v1'
  gem 'nokogiri'
end
