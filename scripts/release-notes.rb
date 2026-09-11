require 'open3'
require 'fileutils'
require 'rexml/document'
require 'cgi'

# Keep release notes tied to the tested commit, even when main moves during delivery.
module ReleaseNotes
  def self.git(repo, *args)
    output, status = Open3.capture2e(ENV.fetch('SNIP_SNAP_GIT', 'git'), '-C', repo, *args)
    raise "Could not read release history: #{output.strip}" unless status.success?
    output.strip
  end

  def self.stem(version, build, channel)
    raise 'Invalid release version' unless version.match?(/\A\d+\.\d+\.\d+\z/)
    raise 'Invalid build number' unless build.match?(/\A[1-9]\d*\z/)
    raise 'Invalid release channel' unless %w[beta stable].include?(channel)
    "Snip-Snap-#{version}#{channel == 'beta' ? "-beta.#{build}" : ''}"
  end

  def self.generate(repo, source, version, build, channel)
    stem(version, build, channel)
    source = git(repo, 'rev-parse', '--verify', "#{source}^{commit}")
    raise 'Release notes need full Git history' if git(repo, 'rev-parse', '--is-shallow-repository') == 'true'
    current_tag = channel == 'beta' ? "v#{version}-beta.#{build}" : "v#{version}"
    tags = git(repo, 'tag', '--merged', source).lines.map(&:strip).select do |tag|
      pattern = channel == 'beta' ? /\Av\d+\.\d+\.\d+(?:-beta\.\d+)?\z/ : /\Av\d+\.\d+\.\d+\z/
      tag.match?(pattern) && tag != current_tag
    end
    tagged_commits = tags.map { |tag| git(repo, 'rev-parse', "#{tag}^{commit}") }
    base = git(repo, 'rev-list', '--first-parent', source).lines.map(&:strip).find { |sha| tagged_commits.include?(sha) }
    range = base ? "#{base}..#{source}" : source
    changes = {'mac' => [], 'ios' => []}
    git(repo, 'log', '--first-parent', '--reverse', '--format=%H', range).lines.map(&:strip).each do |sha|
      paths = git(repo, 'diff-tree', '--root', '--first-parent', '-m', '--no-commit-id', '--name-only', '-r', sha).lines.map(&:strip)
      title = git(repo, 'show', '-s', '--format=%s', sha).sub(/\s*\(#\d+\)\z/, '')
      platforms_for(paths, title).each { |platform| changes.fetch(platform) << title }
    end
    heading = "Snip Snap #{version}#{channel == 'beta' ? " Beta #{build}" : ''}"
    result = {}
    {'mac' => 'Mac', 'ios' => 'iOS'}.each do |platform, label|
      entries = changes.fetch(platform).uniq
      entries = ["No #{label} changes in this build."] if entries.empty?
      result[platform] = "#{heading} — #{label}\n\n#{entries.map { |entry| "- #{entry}" }.join("\n")}\n"
      override = ENV["SNIP_SNAP_#{platform.upcase}_RELEASE_NOTES_FILE"]
      result[platform] = File.read(override) if override && !override.empty?
      raise "#{label} release notes are empty" if result.fetch(platform).strip.empty?
    end
    result['github'] = "# #{heading}\n\n" + {'mac' => 'Mac', 'ios' => 'iOS'}.map do |platform, label|
      body = result.fetch(platform).sub(/\A#{Regexp.escape(heading)} — #{label}\n\n/, '')
      "## #{label}\n\n#{body}"
    end.join("\n")
    result
  end

  def self.platforms_for(paths, title)
    shared = false
    platforms = paths.flat_map do |path|
      case path
      when %r{\ASnipSnap/|\AConfig/(?:Mac|Release\.|Debug\.)} then ['mac']
      when %r{\A(?:SnipSnapiOS|SnipSnapShareExtension)/|\AConfig/(?:iOS|TestFlight)} then ['ios']
      when %r{\APackages/[^/]+/Sources/}
        if File.basename(path).start_with?('Mac')
          ['mac']
        elsif File.basename(path).start_with?('IOS')
          ['ios']
        else
          shared = true
          []
        end
      when 'Shared/Localizable.xcstrings' then []
      when %r{\A(?:Shared|CloudKit)/|\AConfig/Shared\.xcconfig\z}
        shared = true
        []
      else []
      end
    end.uniq
    # Localization edits often accompany a change to just one app.
    shared = true if platforms.empty? && paths.include?('Shared/Localizable.xcstrings')
    named = []
    named << 'mac' if title.match?(/\b(?:Mac|macOS)\b/i)
    named << 'ios' if title.match?(/\b(?:iOS|iPhone|iPad)\b/i)
    # A title that names one platform narrows shared implementation changes.
    shared_platforms = shared ? (named.length == 1 ? named : %w[mac ios]) : []
    (platforms + shared_platforms).uniq
  end

  def self.write(repo, source, version, build, channel, directory)
    result = generate(repo, source, version, build, channel)
    raise 'iOS release notes exceed 4,000 characters; use SNIP_SNAP_IOS_RELEASE_NOTES_FILE with shorter notes' if result.fetch('ios').length > 4_000
    FileUtils.mkdir_p(directory)
    name = stem(version, build, channel)
    File.write(File.join(directory, "#{name}.md"), result.fetch('github'))
    %w[mac ios].each { |platform| File.write(File.join(directory, "#{name}-#{platform}.txt"), result.fetch(platform)) }
  end

  def self.prepare(repo, source, version, build, channel, directory)
    name = stem(version, build, channel)
    files = ["#{name}.md", "#{name}-mac.txt", "#{name}-ios.txt"]
    overridden = %w[MAC IOS].any? { |platform| !ENV.fetch("SNIP_SNAP_#{platform}_RELEASE_NOTES_FILE", '').empty? }
    return if !overridden && files.all? { |file| File.file?(File.join(directory, file)) }
    write(repo, source, version, build, channel, directory)
  end

  def self.verify_appcast_notes(path, version, build, notes_path)
    doc = REXML::Document.new(File.read(path))
    item = doc.get_elements('rss/channel/item').find do |candidate|
      enclosure = candidate.elements['enclosure']
      (candidate.elements['sparkle:version']&.text || enclosure&.attributes&.[]('sparkle:version')) == build &&
        (candidate.elements['sparkle:shortVersionString']&.text || enclosure&.attributes&.[]('sparkle:shortVersionString')) == version
    end
    description = item&.elements&.[]('description')
    unless description && description.attributes['sparkle:format'] == 'plain-text' &&
        description.text == File.read(notes_path) && !item.elements['sparkle:releaseNotesLink']
      raise 'The existing appcast release notes differ; published notes cannot be replaced'
    end
  end

  # Embed the Mac notes so an update never depends on a separate notes URL.
  # Preserve enclosure signatures and every other release item.
  def self.set_appcast_notes(path, version, build, notes_path)
    notes = File.read(notes_path)
    raise 'Release notes are empty' if notes.strip.empty?
    count = 0
    xml = File.read(path).gsub(/<item\b.*?<\/item>/m) do |item|
      next item unless item.match?(/sparkle:version(?:="|>)#{Regexp.escape(build)}(?:"|<)/) &&
        item.match?(/sparkle:shortVersionString(?:="|>)#{Regexp.escape(version)}(?:"|<)/)
      count += 1
      item = item.gsub(/\s*<sparkle:releaseNotesLink\b[^>]*>.*?<\/sparkle:releaseNotesLink>/m, '')
      item = item.gsub(/\s*<description\b[^>]*>.*?<\/description>/m, '')
      item.sub('</item>', "    <description sparkle:format=\"plain-text\">#{CGI.escapeHTML(notes)}</description>\n        </item>")
    end
    raise 'Expected exactly one release notes item in appcast' unless count == 1
    REXML::Document.new(xml)
    File.write(path, xml)
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    case ARGV.shift
    when 'generate'
      raise 'Expected repo, source, version, build, channel, output directory' unless ARGV.length == 6
      ReleaseNotes.write(*ARGV)
    when 'prepare'
      raise 'Expected repo, source, version, build, channel, output directory' unless ARGV.length == 6
      ReleaseNotes.prepare(*ARGV)
    when 'appcast'
      raise 'Expected appcast, version, build, Mac notes file' unless ARGV.length == 4
      ReleaseNotes.set_appcast_notes(*ARGV)
    when 'verify-appcast'
      raise 'Expected appcast, version, build, Mac notes file' unless ARGV.length == 4
      ReleaseNotes.verify_appcast_notes(*ARGV)
    else
      raise 'Use generate or appcast'
    end
  rescue StandardError => error
    warn "Release notes: #{error.message}"
    exit 1
  end
end
