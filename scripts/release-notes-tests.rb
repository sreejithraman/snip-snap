require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'release-notes'

class ReleaseNotesTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('snip-snap-notes-')
    git('init', '-q', '--initial-branch=main')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    commit('Shared/base.swift', 'Initial release')
    git('tag', 'v0.4.1')
    commit('SnipSnap/Panel.swift', 'Fix Mac panel contrast (#1)')
    FileUtils.mkdir_p(File.join(@dir, 'SnipSnap.xcodeproj'))
    File.write(File.join(@dir, 'SnipSnap.xcodeproj/project.pbxproj'), 'Mac file reference')
    git('add', '.')
    git('commit', '--amend', '--no-edit', '-q')
    git('tag', 'v0.5.0-beta.1')
    commit('SnipSnapiOS/Paste.swift', 'Fix iPhone paste (#2)')
    commit('Shared/Sync.swift', 'Fix sync & recovery (#3)')
    commit('appcast.xml', 'Publish Snip Snap 0.5.0 beta 2')
    commit('docs/check.md', 'Update contributor docs')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    out, status = Open3.capture2e('git', '-C', @dir, *args)
    raise out unless status.success?
    out.strip
  end

  def commit(path, message)
    FileUtils.mkdir_p(File.dirname(File.join(@dir, path)))
    File.write(File.join(@dir, path), message)
    git('add', path)
    git('commit', '-qm', message)
  end

  def notes(channel, source = 'HEAD')
    ReleaseNotes.generate(@dir, source, '0.5.0', '2', channel)
  end

  def test_beta_uses_previous_beta_and_splits_platforms
    result = notes('beta')
    refute_includes result.fetch('mac'), 'iPhone'
    refute_includes result.fetch('mac'), 'contrast'
    assert_includes result.fetch('ios'), 'Fix iPhone paste'
    %w[mac ios].each do |platform|
      assert_includes result.fetch(platform), 'Fix sync & recovery'
      refute_includes result.fetch(platform), 'Publish Snip'
      refute_includes result.fetch(platform), 'contributor docs'
    end
  end

  def test_stable_covers_all_changes_since_previous_stable
    result = notes('stable')
    assert_includes result.fetch('mac'), 'Fix Mac panel contrast'
    refute_includes result.fetch('ios'), 'Fix Mac panel contrast'
    assert_includes result.fetch('ios'), 'Fix iPhone paste'
    assert_includes result.fetch('github'), "## Mac\n"
    assert_includes result.fetch('github'), "## iOS\n"
  end

  def test_retry_and_later_commits_do_not_change_notes
    original = notes('beta')
    source = git('rev-parse', 'HEAD')
    git('tag', 'v0.5.0-beta.2')
    commit('Shared/Later.swift', 'Do not include this later change')
    assert_equal original, notes('beta', source)
  end

  def test_platform_specific_changes_in_shared_files
    assert_equal ['mac'], ReleaseNotes.platforms_for(
      ['Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/MacLocalSnipLibraryBootstrap.swift'],
      'Open the Mac live store as SwiftData only')
    assert_equal ['ios'], ReleaseNotes.platforms_for(
      ['SnipSnapiOS/IconPicker.swift', 'Shared/Localizable.xcstrings'], 'Add iOS list icon picker')
    assert_equal ['ios'], ReleaseNotes.platforms_for(
      ['Shared/AccountNotice.swift', 'SnipSnapiOS/App.swift'], 'Fix repeated iCloud alert on iOS foreground')
    assert_equal ['mac'], ReleaseNotes.platforms_for(
      ['Shared/AccountNotice.swift', 'SnipSnap/Panel.swift'], 'Fix Mac account notice')
    assert_equal %w[mac ios], ReleaseNotes.platforms_for(
      ['Shared/Sync.swift'], 'Fix shared sync recovery')
    assert_equal %w[mac ios], ReleaseNotes.platforms_for(
      ['SnipSnap/Panel.swift', 'SnipSnapiOS/App.swift'], 'Align Mac and iOS controls')
    assert_equal ['mac'], ReleaseNotes.platforms_for(['SnipSnap/Panel.swift'], 'Match the iOS panel spacing')
    assert_equal ['ios'], ReleaseNotes.platforms_for(['SnipSnapiOS/App.swift'], 'Match Mac controls')
    assert_equal %w[mac ios], ReleaseNotes.platforms_for(
      ['SnipSnap/Panel.swift', 'SnipSnapiOS/App.swift'], 'Match Mac controls')
  end

  def test_oversized_ios_notes_fail_before_writing_release_files
    commit('SnipSnapiOS/Large.swift', 'Fix ' + 'large change ' * 350)
    output = File.join(@dir, 'notes-output')
    assert_raises(RuntimeError) { ReleaseNotes.write(@dir, 'HEAD', '0.5.0', '2', 'stable', output) }
    refute File.exist?(output)
    override = File.join(@dir, 'short-ios-notes.txt')
    File.write(override, "- Fix iOS paste.\n")
    previous_override = ENV['SNIP_SNAP_IOS_RELEASE_NOTES_FILE']
    begin
      ENV['SNIP_SNAP_IOS_RELEASE_NOTES_FILE'] = override
      ReleaseNotes.write(@dir, 'HEAD', '0.5.0', '2', 'stable', output)
      assert_equal File.read(override), File.read(File.join(output, 'Snip-Snap-0.5.0-ios.txt'))
      assert_includes File.read(File.join(output, 'Snip-Snap-0.5.0.md')), '- Fix iOS paste.'
    ensure
      ENV['SNIP_SNAP_IOS_RELEASE_NOTES_FILE'] = previous_override
    end
  end

  def test_platform_overrides_refresh_cached_notes_and_github_sections
    output = File.join(@dir, 'cached-notes')
    ReleaseNotes.prepare(@dir, 'HEAD', '0.5.0', '2', 'beta', output)
    overrides = {}
    %w[MAC IOS].each do |platform|
      key = "SNIP_SNAP_#{platform}_RELEASE_NOTES_FILE"
      overrides[key] = ENV[key]
      file = File.join(@dir, "#{platform}.txt")
      File.write(file, "- Authored #{platform} notes.\n")
      ENV[key] = file
    end
    begin
      ReleaseNotes.prepare(@dir, 'HEAD', '0.5.0', '2', 'beta', output)
      %w[mac ios].each do |platform|
        assert_equal "- Authored #{platform.upcase} notes.\n", File.read(File.join(output, "Snip-Snap-0.5.0-beta.2-#{platform}.txt"))
        assert_includes File.read(File.join(output, 'Snip-Snap-0.5.0-beta.2.md')), "Authored #{platform.upcase} notes."
      end
    ensure
      overrides.each { |key, previous| ENV[key] = previous }
    end
  end

  def test_first_release_and_platform_without_changes
    result = ReleaseNotes.generate(@dir, 'v0.5.0-beta.1', '0.5.0', '1', 'beta')
    assert_includes result.fetch('mac'), 'Fix Mac panel contrast'
    assert_includes result.fetch('ios'), 'No iOS changes in this build.'
    first = ReleaseNotes.generate(@dir, 'v0.4.1', '0.4.1', '1', 'stable')
    assert_includes first.fetch('mac'), 'Initial release'
  end

  def test_appcast_embeds_platform_notes_and_preserves_other_items
    xml = '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>2</sparkle:version><sparkle:shortVersionString>0.5.0</sparkle:shortVersionString><sparkle:releaseNotesLink>https://example.invalid/missing.md</sparkle:releaseNotesLink><description>wrong notes</description><enclosure url="app.zip" sparkle:edSignature="unchanged"/></item><item><title>Older</title></item></channel></rss>'
    path = File.join(@dir, 'feed.xml')
    File.write(path, xml)
    %w[beta stable].each do |channel|
      notes_path = File.join(@dir, "#{channel}-mac.txt")
      File.write(notes_path, notes(channel).fetch('mac'))
      ReleaseNotes.set_appcast_notes(path, '0.5.0', '2', notes_path)
      doc = REXML::Document.new(File.read(path))
      item = doc.elements['rss/channel/item']
      assert_equal File.read(notes_path), item.elements['description'].text
      assert_equal 'plain-text', item.elements['description'].attributes['sparkle:format']
      assert_nil item.elements['sparkle:releaseNotesLink']
      assert_equal 'unchanged', item.elements['enclosure'].attributes['sparkle:edSignature']
      assert_includes File.read(path), '<item><title>Older</title></item>'
      ReleaseNotes.verify_appcast_notes(path, '0.5.0', '2', notes_path)
      File.write(notes_path, 'Changed after publishing')
      assert_raises(RuntimeError) { ReleaseNotes.verify_appcast_notes(path, '0.5.0', '2', notes_path) }
    end
    assert_raises(RuntimeError) { ReleaseNotes.set_appcast_notes(path, '0.5.0', '999', File.join(@dir, 'stable-mac.txt')) }
  end
end
