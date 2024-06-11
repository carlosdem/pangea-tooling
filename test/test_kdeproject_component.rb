# frozen_string_literal: true
require 'test/unit'

require 'webmock'
require 'webmock/test_unit'

require_relative 'lib/testcase'
require_relative '../lib/kdeproject_component'

require 'mocha/test_unit'

class KDEProjectComponentTest < TestCase
  def test_kdeprojectcomponent
    stub_request(:get, 'https://projects.kde.org/api/v1/projects/frameworks')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: '["frameworks/attica","frameworks/baloo","frameworks/bluez-qt"]', headers: { 'Content-Type' => 'text/json' })

    stub_request(:get, 'https://raw.githubusercontent.com/KDE/releaseme/master/plasma/git-repositories-for-release-plasma')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: 'bluedevil breeze breeze-grub breeze-gtk breeze-plymouth discover drkonqi kactivitymanagerd kde-cli-tools kde-gtk-config kdecoration kdeplasma-addons kgamma5 khotkeys kinfocenter kmenuedit kscreen kscreenlocker ksshaskpass ksystemstats kwallet-pam kwayland-integration kwayland-server kwin kwrited layer-shell-qt libkscreen libksysguard milou oxygen plasma-browser-integration plasma-desktop plasma-disks plasma-firewall plasma-integration plasma-nano plasma-nm plasma-pa plasma-phone-components plasma-sdk plasma-systemmonitor plasma-tests plasma-thunderbolt plasma-vault plasma-workspace plasma-workspace-wallpapers plymouth-kcm polkit-kde-agent-1 powerdevil qqc2-breeze-style sddm-kcm systemsettings xdg-desktop-portal-kde ', headers: { 'Content-Type' => 'text/json' })

    stub_request(:get, 'https://projects.kde.org/api/v1/projects/pim')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: '["pim/kjots","pim/kmime"]', headers: { 'Content-Type' => 'text/json' })

    stub_request(:get, 'https://projects.kde.org/api/v1/projects/')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: '["plasma/khotkeys","sdk/umbrello", "education/analitza", "documentation/digiam-doc", "historical/kde1, "kdevelop/kdev-php", "libraries/kdb", "maui/buho", "multimedia/k3b", "network/choqok", "office/calligra", "unmaintained/contour"]', headers: { 'Content-Type' => 'text/json' })

    stub_request(:get, 'https://invent.kde.org/sysadmin/release-tools/-/raw/master/modules.git')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: "kdialog                                     master\nkeditbookmarks                              master\n", headers: { 'Content-Type' => 'text/plain' })

    stub_request(:get, 'https://raw.githubusercontent.com/KDE/releaseme/master/plasma/git-repositories-for-release')
      .with(headers: { 'Accept' => '*/*', 'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3', 'User-Agent' => 'Ruby' })
      .to_return(status: 200, body: 'bluedevil breeze breeze-grub breeze-gtk breeze-plymouth discover drkonqi', headers: { 'Content-Type' => 'text/plain' })

    f = KDEProjectsComponent.frameworks
    p = KDEProjectsComponent.plasma
    plasma_jobs = KDEProjectsComponent.plasma_jobs
    pim = KDEProjectsComponent.pim
    assert f.include? 'attica'
    assert p.include? 'bluedevil'
    assert plasma_jobs.include? 'plasma-discover'
    assert !plasma_jobs.include?('discover')
    assert pim.include? 'kjots'
    assert pim.include? 'kmime'
  end
end
