require 'open3'
require 'yaml'

module CIChanges
  SHARED_MAC_PATHS = %w[
    SnipSnap/SnipListIconCatalog.swift
    SnipSnapTests/AppFeedbackTests.swift
  ].freeze

  def self.git(*args)
    output, status = Open3.capture2e('git', *args)
    raise "Could not inspect CI changes: #{output.strip}" unless status.success?
    output
  end

  def self.paths(base, head)
    merge_base = git('merge-base', base, head).strip
    git('diff', '--name-only', '--no-renames', '-z', merge_base, head, '--').split("\0")
  end

  def self.documentation?(path)
    path.start_with?('docs/') || (path.start_with?('.agents/') && path.end_with?('.md')) ||
      (!path.include?('/') && path.end_with?('.md')) ||
      %w[LICENSE appcast.xml].include?(path)
  end

  def self.pr_checks(base, head)
    changed = paths(base, head).reject { |path| documentation?(path) }
    mac_only = changed.all? do |path|
      next false if SHARED_MAC_PATHS.include?(path)
      path.start_with?('SnipSnap/', 'SnipSnapTests/') ||
        path.match?(%r{\AConfig/(?:Mac|Debug\.|Release\.)})
    end
    { 'mac' => !changed.empty?, 'ios' => !changed.empty? && !mac_only }
  end

  def self.current?(source, main)
    # Publishing metadata and docs may advance main without replacing its tested app inputs.
    return false unless git('merge-base', source, main).strip == git('rev-parse', source).strip
    workflow = YAML.load_file('.github/workflows/beta-candidate.yml')
    watched = workflow.fetch('on', workflow[true]).fetch('push').fetch('paths')
    changed = git('log', '--first-parent', '--format=%H', "#{source}..#{main}", '--',
                  *watched.map { |path| ":(glob)#{path}" })
    changed.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    mode, base, head = ARGV
    raise 'Use pr BASE HEAD or current SOURCE MAIN' unless ARGV.length == 3
    case mode
    when 'pr'
      CIChanges.pr_checks(base, head).each { |key, value| puts "#{key}=#{value}" }
    when 'current'
      puts "current=#{CIChanges.current?(base, head)}"
    else
      raise 'Use pr BASE HEAD or current SOURCE MAIN'
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
