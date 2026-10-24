require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ChangelogTest < Minitest::Test
  def setup
    @repo = Dir.mktmpdir('snip-snap-changelog-')
    FileUtils.mkdir_p(File.join(@repo, 'docs/releases'))
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def notes(version, text)
    File.write(File.join(@repo, 'docs/releases', "Snip-Snap-#{version}.md"), text)
  end

  def feed(*items)
    File.write(File.join(@repo, 'appcast.xml'), <<~XML)
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
      #{items.join("\n")}
      </channel></rss>
    XML
  end

  def item(version, date, channel = nil)
    <<~XML
      <item>
        <sparkle:shortVersionString>#{version}</sparkle:shortVersionString>
        <pubDate>#{date}</pubDate>
        #{"<sparkle:channel>#{channel}</sparkle:channel>" if channel}
      </item>
    XML
  end

  def generate
    Open3.capture2e('/usr/bin/ruby', File.join(__dir__, 'release-notes.rb'), 'changelog', @repo)
  end

  def changelog
    File.read(File.join(@repo, 'docs/CHANGELOG.md'))
  end

  def test_changelog_shows_stable_history_newest_first_with_dates_and_platform_notes
    notes('0.9.0', "Snip Snap 0.9.0\n\n- Fix capture.\n")
    notes('0.10.0', "# Snip Snap 0.10.0\n\n## Mac\n\n- Add lists.\n\n## iOS\n\n- Fix paste.\n")
    notes('0.11.0', "# Snip Snap 0.11.0\n\n- Not published.\n")
    feed(item('0.9.0', 'Thu, 01 Oct 2026 12:00:00 +0000'),
         item('0.11.0', 'Sat, 03 Oct 2026 12:00:00 +0000', 'beta'),
         item('0.10.0', 'Fri, 02 Oct 2026 12:00:00 +0000'))

    output, status = generate
    assert status.success?, output
    assert_includes changelog, "## [0.10.0](releases/Snip-Snap-0.10.0.md) - 2026-10-02\n\n### Mac\n\n- Add lists.\n\n### iOS\n\n- Fix paste."
    assert_includes changelog, "## [0.9.0](releases/Snip-Snap-0.9.0.md) - 2026-10-01\n\n- Fix capture."
    assert_operator changelog.index('## [0.10.0]'), :<, changelog.index('## [0.9.0]')
    refute_includes changelog, '0.11.0'
    refute_includes changelog, '# Snip Snap'
  end

  def test_missing_stable_history_does_not_replace_an_existing_changelog
    File.write(File.join(@repo, 'docs/CHANGELOG.md'), "Existing history.\n")
    feed(item('0.11.0', 'Sat, 03 Oct 2026 12:00:00 +0000', 'beta'))

    output, status = generate
    refute status.success?, output
    assert_includes output, 'No stable releases'
    assert_equal "Existing history.\n", changelog
  end

  def test_legacy_releases_without_details_remain_visible
    notes('0.1.0', "Snip Snap 0.1.0\n")
    feed(item('0.1.0', 'Mon, 24 Aug 2026 15:55:11 -0400'))

    output, status = generate
    assert status.success?, output
    assert_includes changelog, "## [0.1.0](releases/Snip-Snap-0.1.0.md) - 2026-08-24\n\nNo detailed notes were recorded for this release.\n"
  end

  def test_promotion_and_retry_keep_history_current_without_changing_published_inputs
    notes('0.9.0', "Snip Snap 0.9.0\n\n- Fix capture.\n")
    older = item('0.9.0', 'Thu, 01 Oct 2026 12:00:00 +0000')
    feed(older)
    output, status = generate
    assert status.success?, output
    previous = changelog

    notes('0.10.0', "# Snip Snap 0.10.0\n\n## Mac\n\n- Add lists.\n")
    feed(older, item('0.10.0', 'Fri, 02 Oct 2026 12:00:00 +0000', 'default'))
    inputs = Dir.glob(File.join(@repo, 'docs/releases/*')) + [File.join(@repo, 'appcast.xml')]
    original_bytes = inputs.map { |path| [path, File.binread(path)] }.to_h
    output, status = generate
    assert status.success?, output
    promoted = changelog
    assert_includes promoted, previous.split('## [0.9.0]').last
    assert_equal 1, promoted.scan('## [0.10.0]').length

    output, status = generate
    assert status.success?, output
    assert_equal promoted, changelog
    original_bytes.each { |path, bytes| assert_equal bytes, File.binread(path) }
  end

  def test_incomplete_stable_release_does_not_replace_existing_history
    File.write(File.join(@repo, 'docs/CHANGELOG.md'), "Existing history.\n")
    feed(item('0.10.0', 'Fri, 02 Oct 2026 12:00:00 +0000'))

    output, status = generate
    refute status.success?, output
    assert_includes output, 'Snip-Snap-0.10.0.md'
    assert_equal "Existing history.\n", changelog
  end

  def test_checked_in_changelog_matches_published_stable_history
    project = File.expand_path('..', __dir__)
    FileUtils.cp(File.join(project, 'appcast.xml'), File.join(@repo, 'appcast.xml'))
    FileUtils.cp(Dir.glob(File.join(project, 'docs/releases/*.md')), File.join(@repo, 'docs/releases'))

    output, status = generate
    assert status.success?, output
    assert_equal File.read(File.join(project, 'docs/CHANGELOG.md')), changelog,
      'Regenerate docs/CHANGELOG.md with: /usr/bin/ruby scripts/release-notes.rb changelog .'
  end
end
