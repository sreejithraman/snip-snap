require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'yaml'
require 'json'

class CIChangesTest < Minitest::Test
  SCRIPT = File.expand_path('ci-changes.rb', __dir__)

  def setup
    @repo = Dir.mktmpdir('snip-snap-ci-changes-')
    git('init', '-q', '--initial-branch=main')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    git('config', 'commit.gpgsign', 'false')
    git('config', 'maintenance.auto', 'false')
    FileUtils.mkdir_p(File.join(@repo, '.github/workflows'))
    FileUtils.cp(File.expand_path('../.github/workflows/beta-candidate.yml', __dir__),
                 File.join(@repo, '.github/workflows/beta-candidate.yml'))
    git('add', '.')
    git('commit', '-qm', 'Initial')
    @base = git('rev-parse', 'HEAD')
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def git(*args)
    output, status = Open3.capture2e('git', '-C', @repo, *args)
    raise output unless status.success?
    output.strip
  end

  def commit(path)
    FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
    File.write(File.join(@repo, path), git('rev-parse', 'HEAD'))
    git('add', '--', path)
    git('commit', '-qm', path)
    git('rev-parse', 'HEAD')
  end

  def selection(mode, base = @base, head = 'HEAD')
    output, status = Open3.capture2e('/usr/bin/ruby', SCRIPT, mode, base, head, chdir: @repo)
    assert status.success?, output
    output.lines.map(&:strip)
  end

  def test_shared_ios_and_unknown_inputs_keep_both_groups
    ['Shared/Sync.swift', 'SnipSnapiOS/Composer.swift', 'SnipSnap.xcodeproj/project.pbxproj',
     'Packages/SnipSnapLibrary/Sources/SnipSnapPersistence/MacStore.swift',
     'SnipSnap/SnipListIconCatalog.swift',
     '.agents/skills/example/scripts/verify.sh',
     'scripts/test.sh', '.github/workflows/ci.yml', 'new-build-input'].each do |path|
      commit(path)
      assert_equal %w[mac=true ios=true], selection('pr')
      @base = git('rev-parse', 'HEAD')
    end
  end

  def test_overlapping_prs_select_only_changes_since_the_merge_base
    { 'docs' => ['docs/guide.md', %w[mac=false ios=false]],
      'mac' => ['SnipSnap/Panel.swift', %w[mac=true ios=false]] }.each do |name, (path, expected)|
      git('checkout', '-qb', name, @base)
      head = commit(path)
      git('checkout', '-q', 'main')
      commit('Shared/Sync.swift')
      commit('SnipSnap.xcodeproj/project.pbxproj')
      assert_equal expected, selection('pr', 'main', head), name
    end
  end

  def test_ios_target_members_inside_mac_directories_run_both_groups
    project = File.expand_path('../SnipSnap.xcodeproj/project.pbxproj', __dir__)
    output, status = Open3.capture2e('/usr/bin/plutil', '-convert', 'json', '-o', '-', project)
    assert status.success?, output
    data = JSON.parse(output)
    objects = data.fetch('objects')
    root = objects.fetch(data.fetch('rootObject'))
    paths = {}
    visit = lambda do |id, parent|
      node = objects.fetch(id)
      paths[id] = [parent, node['path']].compact.reject(&:empty?).join('/')
      node.fetch('children', []).each { |child| visit.call(child, paths.fetch(id)) }
    end
    visit.call(root.fetch('mainGroup'), '')
    shared_paths = root.fetch('targets').flat_map do |id|
      target = objects.fetch(id)
      next [] unless target.fetch('name').match?(/iOS|ShareExtension/)
      target.fetch('buildPhases').flat_map do |phase|
        objects.fetch(phase).fetch('files', []).map do |file|
          paths[objects.fetch(file)['fileRef']]
        end
      end
    end.compact.uniq.select { |path| path.start_with?('SnipSnap/', 'SnipSnapTests/') }
    refute_empty shared_paths
    shared_paths.each do |path|
      commit(path)
      assert_equal %w[mac=true ios=true], selection('pr'), path
      @base = git('rev-parse', 'HEAD')
    end
  end

  def test_deletion_and_rename_into_other_platform_are_checked
    commit('SnipSnap/Panel.swift')
    @base = git('rev-parse', 'HEAD')
    FileUtils.mkdir_p(File.join(@repo, 'SnipSnapiOS'))
    git('mv', 'SnipSnap/Panel.swift', 'SnipSnapiOS/Panel.swift')
    git('commit', '-qm', 'Move to iOS')
    assert_equal %w[mac=true ios=true], selection('pr')
    @base = git('rev-parse', 'HEAD')
    git('rm', 'SnipSnapiOS/Panel.swift')
    git('commit', '-qm', 'Remove')
    assert_equal %w[mac=true ios=true], selection('pr')
  end

  def test_docs_and_publishing_metadata_do_not_discard_tested_app
    commit('SnipSnap/Panel.swift')
    @base = git('rev-parse', 'HEAD')
    assert_equal ['current=true'], selection('current')
    commit('docs/releases/build.md')
    commit('appcast.xml')
    assert_equal ['current=true'], selection('current')
  end

  def test_a_later_release_input_replaces_candidate
    ['SnipSnap/Panel.swift', 'SnipSnapiOS/Composer.swift', 'Shared/Sync.swift',
     'scripts/release.sh', '.github/workflows/ci.yml', 'Config/release.json'].each do |path|
      commit(path)
      assert_equal ['current=false'], selection('current')
      @base = git('rev-parse', 'HEAD')
    end
  end

  def test_change_followed_by_revert_does_not_revive_an_older_candidate
    path = 'SnipSnap/Panel.swift'
    commit(path)
    @base = git('rev-parse', 'HEAD')
    original = File.read(File.join(@repo, path))
    commit(path)
    File.write(File.join(@repo, path), original)
    git('add', path)
    git('commit', '-qm', 'Revert app change')
    assert_empty git('diff', '--name-only', @base, 'HEAD')
    assert_equal ['current=false'], selection('current')
  end

  def test_stable_promotion_and_beta_delivery_share_a_non_cancelling_queue
    concurrency = %w[beta.yml promote-stable.yml].map do |name|
      YAML.load_file(File.expand_path("../.github/workflows/#{name}", __dir__)).fetch('concurrency')
    end
    refute_empty concurrency.first.fetch('group')
    assert_equal concurrency.first.fetch('group'), concurrency.last.fetch('group')
    concurrency.each do |config|
      assert_equal 'max', config['queue']
      assert_equal false, config['cancel-in-progress']
    end
  end

  def test_candidate_from_another_branch_cannot_publish
    git('checkout', '-qb', 'side')
    source = commit('SnipSnap/Panel.swift')
    git('checkout', '-q', 'main')
    commit('docs/notes.md')
    assert_equal ['current=false'], selection('current', source)
  end

  def test_delivery_step_uses_fetched_main_and_preserves_tested_checkout
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.cp(SCRIPT, File.join(@repo, 'scripts/ci-changes.rb'))
    git('add', '.')
    git('commit', '-qm', 'CI tools')
    source = git('rev-parse', 'HEAD')
    remote = File.join(@repo, 'origin.git')
    git('init', '-q', '--bare', remote)
    git('remote', 'add', 'origin', remote)
    workflow = YAML.load_file(File.expand_path('../.github/workflows/beta.yml', __dir__))
    command = workflow.fetch('jobs').fetch('prepare').fetch('steps').find { |step| step['id'] == 'source' }.fetch('run')
    ['docs/guide.md', 'SnipSnap/Panel.swift'].each do |path|
      git('checkout', '-q', 'main')
      commit(path)
      git('push', '-q', 'origin', 'main')
      git('checkout', '-q', '--detach', source)
      output_file = File.join(@repo, 'source-output')
      File.write(output_file, '')
      output, status = Open3.capture2e({ 'SOURCE_SHA' => source, 'GITHUB_OUTPUT' => output_file },
                                     '/bin/bash', '-e', '-c', command, chdir: @repo)
      assert status.success?, output
      expected = path.start_with?('docs/') ? 'current=true' : 'current=false'
      assert_equal expected, File.read(output_file).strip
      assert_equal source, git('rev-parse', 'HEAD')
    end
  end

  def test_signed_build_source_guards_accept_started_candidate_after_main_advances
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.mkdir_p(File.join(@repo, 'Config'))
    FileUtils.cp(File.expand_path('release-policy.sh', __dir__), File.join(@repo, 'scripts/release-policy.sh'))
    File.write(File.join(@repo, 'Config/release.json'), '{"version":"0.7.0"}')
    File.write(File.join(@repo, 'Config/Shared.xcconfig'), "MARKETING_VERSION = 0.7.0\nCURRENT_PROJECT_VERSION = 1\n")
    File.write(File.join(@repo, 'appcast.xml'), '<rss><channel></channel></rss>')
    git('add', '.')
    git('commit', '-qm', 'Release inputs')
    source = git('rev-parse', 'HEAD')
    Dir.mktmpdir('snip-snap-source-remote-') do |root|
      remote = File.join(root, 'origin.git')
      git('init', '-q', '--bare', remote)
      git('remote', 'add', 'origin', remote)
      gh = File.join(root, 'gh')
      File.write(gh, "#!/bin/sh\ncase \"$*\" in\n  'repo view '*) echo false ;;\n  *compare*) echo \"${COMPARE_STATUS:-ahead}\" ;;\n  *) exit 1 ;;\nesac\n")
      File.chmod(0755, gh)
      commit('docs/guide.md')
      git('push', '-q', 'origin', 'main')
      git('checkout', '-q', '--detach', source)
      env = { 'SNIP_SNAP_GH' => gh, 'SNIP_SNAP_RELEASE_SOURCE_RELATION' => nil }
      guards = {
        'mac-build' => File.read(File.expand_path('release.sh', __dir__)).lines.find do |line|
          line.start_with?('release_policy_preflight ')
        end,
        'ios-upload' => File.read(File.expand_path('testflight.sh', __dir__)).match(
          /^        release_policy_require_source .*\\\n[^\n]+/)[0]
      }
      jobs = YAML.load_file(File.expand_path('../.github/workflows/beta.yml', __dir__)).fetch('jobs')
      guards.each do |job, guard|
        command = 'source scripts/release-policy.sh; repo_dir="$PWD"; release_repo=test/repo; requested_build=7; ' + guard
        output, status = Open3.capture2e(env, '/bin/zsh', '-e', '-c', command, chdir: @repo)
        refute status.success?, "Default local guard accepted an older commit: #{output}"
        relation = jobs.fetch(job).fetch('env')['SNIP_SNAP_RELEASE_SOURCE_RELATION']
        assert_equal 'on-main', relation
        output, status = Open3.capture2e(env.merge('SNIP_SNAP_RELEASE_SOURCE_RELATION' => relation),
                                       '/bin/zsh', '-e', '-c', command, chdir: @repo)
        assert status.success?, "#{job} rejected its started candidate: #{output}"
        output, status = Open3.capture2e(env.merge('SNIP_SNAP_RELEASE_SOURCE_RELATION' => relation,
                                                'COMPARE_STATUS' => 'diverged'),
                                       '/bin/zsh', '-e', '-c', command, chdir: @repo)
        refute status.success?, "#{job} accepted an off-main source: #{output}"
      end
    end
  end

  def test_partial_retry_rechecks_stable_version_before_upload_or_new_publication
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.mkdir_p(File.join(@repo, 'Config'))
    FileUtils.cp(File.expand_path('release-policy.sh', __dir__), File.join(@repo, 'scripts/release-policy.sh'))
    File.write(File.join(@repo, 'Config/release.json'), '{"version":"0.7.0"}')
    git('add', '.')
    git('commit', '-qm', 'Prepared beta source')
    source = git('rev-parse', 'HEAD')
    Dir.mktmpdir('snip-snap-retry-') do |root|
      remote = File.join(root, 'origin.git')
      git('init', '-q', '--bare', remote)
      git('remote', 'add', 'origin', remote)
      git('push', '-q', 'origin', 'main')
      marker = File.join(root, 'published')
      gh = File.join(root, 'gh')
      File.write(gh, <<~SH)
        #!/bin/sh
        case "$*" in
          'repo view '*) echo false ;;
          *compare*) echo ahead ;;
          'release create '*) echo published > "$PUBLISH_MARKER" ;;
          *) exit 1 ;;
        esac
      SH
      File.chmod(0755, gh)
      upload = File.read(File.expand_path('testflight.sh', __dir__))[/^    upload\)\n(.*?)        \[\[ -d/m, 1]
      publish = File.read(File.expand_path('publish-beta.sh', __dir__))[/^if \(\( ! release_exists \)\); then\n.*?^fi/m]
      refute_nil upload
      refute_nil publish
      env = { 'SNIP_SNAP_GH' => gh, 'SNIP_SNAP_RELEASE_SOURCE_RELATION' => 'on-main',
              'SNIP_SNAP_RELEASE_CHECKS_PASSED' => 'YES', 'GITHUB_RUN_ATTEMPT' => '2', 'PUBLISH_MARKER' => marker }
      prefix = 'source scripts/release-policy.sh; release_policy_load_release Config/release.json 7; ' \
               'repo_dir="$PWD"; release_checkout="$PWD"; gh_tool="$SNIP_SNAP_GH"; release_repo=test/repo; release_exists=0; '
      [upload, publish].each do |command|
        output, status = Open3.capture2e(env, '/bin/zsh', '-e', '-c', prefix + command, chdir: @repo)
        assert status.success?, output
      end
      File.delete(marker)
      git('tag', 'v0.7.0')
      commit('appcast.xml')
      git('push', '-q', 'origin', 'main', '--tags')
      git('checkout', '-q', '--detach', source)
      [upload, publish].each do |command|
        output, status = Open3.capture2e(env, '/bin/zsh', '-e', '-c', prefix + command, chdir: @repo)
        refute status.success?, "Retry accepted a version already promoted stable: #{output}"
        assert_includes output, 'must be newer than v0.7.0'
      end
      refute File.exist?(marker), 'Retry created a new beta after stable promotion'
      output, status = Open3.capture2e(env, '/bin/zsh', '-e', '-c',
                                     prefix + 'release_exists=1; ' + publish, chdir: @repo)
      assert status.success?, "Recovery of an existing matching beta was blocked: #{output}"
      refute File.exist?(marker), 'Existing beta recovery must not create a release'
    end
  end

  def test_docs_only_pr_keeps_the_repository_wide_policy
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.cp(File.expand_path('tracked-input-policy.sh', __dir__), File.join(@repo, 'scripts/tracked-input-policy.sh'))
    git('add', '.')
    git('commit', '-qm', 'Policy baseline')
    @base = git('rev-parse', 'HEAD')
    commit('docs/building.md')
    assert_equal %w[mac=false ios=false], selection('pr')
    workflow = YAML.load_file(File.expand_path('../.github/workflows/ci.yml', __dir__))
    step = workflow.fetch('jobs').fetch('changes').fetch('steps').find { |entry| entry['name'] == 'Check tracked inputs' }
    refute_nil step, 'Docs-only PRs must still run the existing repository-wide policy'
    output, status = Open3.capture2e('/bin/bash', '-e', '-c', step.fetch('run'), chdir: @repo)
    assert status.success?, output
    File.write(File.join(@repo, 'docs/building.md'), ['/Users', 'fixture-person', 'private'].join('/'))
    git('add', 'docs/building.md')
    git('commit', '-qm', 'Forbidden documentation value')
    output, status = Open3.capture2e('/bin/bash', '-e', '-c', step.fetch('run'), chdir: @repo)
    refute status.success?, 'The always-run policy accepted a forbidden documentation value'
    assert_includes output, 'personal home path'
    refute_includes output, 'fixture-person'
  end

  def test_feed_and_history_only_prs_keep_release_history_validation
    project = File.expand_path('..', __dir__)
    FileUtils.mkdir_p(File.join(@repo, 'scripts'))
    FileUtils.mkdir_p(File.join(@repo, 'docs/releases'))
    %w[changelog-tests.rb release-notes.rb].each do |name|
      FileUtils.cp(File.join(project, 'scripts', name), File.join(@repo, 'scripts', name))
    end
    FileUtils.cp(File.join(project, 'appcast.xml'), File.join(@repo, 'appcast.xml'))
    FileUtils.cp(File.join(project, 'docs/CHANGELOG.md'), File.join(@repo, 'docs/CHANGELOG.md'))
    FileUtils.cp(Dir.glob(File.join(project, 'docs/releases/*.md')), File.join(@repo, 'docs/releases'))
    git('add', '.')
    git('commit', '-qm', 'Release history baseline')
    @base = git('rev-parse', 'HEAD')
    workflow = YAML.load_file(File.join(project, '.github/workflows/ci.yml'))
    step = workflow.fetch('jobs').fetch('changes').fetch('steps').find { |entry| entry['name'] == 'Check release history' }
    refute_nil step, 'Feed-only PRs must retain the existing release-history validation'
    output, status = Open3.capture2e('/bin/bash', '-e', '-c', step.fetch('run'), chdir: @repo)
    assert status.success?, output
    File.open(File.join(@repo, 'appcast.xml'), 'a') { |file| file.write('<') }
    git('add', 'appcast.xml')
    git('commit', '-qm', 'Malformed feed')
    assert_equal %w[mac=false ios=false], selection('pr')
    output, status = Open3.capture2e('/bin/bash', '-e', '-c', step.fetch('run'), chdir: @repo)
    refute status.success?, "The lightweight job accepted a malformed feed: #{output}"
    FileUtils.cp(File.join(project, 'appcast.xml'), File.join(@repo, 'appcast.xml'))
    File.open(File.join(@repo, 'docs/CHANGELOG.md'), 'a') { |file| file.write('Unpublished history') }
    git('add', '.')
    git('commit', '-qm', 'Inconsistent changelog')
    assert_equal %w[mac=false ios=false], selection('pr')
    output, status = Open3.capture2e('/bin/bash', '-e', '-c', step.fetch('run'), chdir: @repo)
    refute status.success?, "The lightweight job accepted inconsistent history: #{output}"
  end

  def test_invalid_git_revision_fails_closed
    [['missing', 'HEAD'], ['', '']].each do |base, head|
      output, status = Open3.capture2e('/usr/bin/ruby', SCRIPT, 'pr', base, head, chdir: @repo)
      refute status.success?
      refute_includes output, 'mac=false'
    end
  end

  def test_docs_only_pr_needs_no_mac_runners
    %w[docs/building.md GLOSSARY.md THIRD_PARTY_NOTICES.md].each do |path|
      commit(path)
      assert_equal %w[mac=false ios=false], selection('pr'), path
      @base = git('rev-parse', 'HEAD')
    end
  end

  def test_mac_only_pr_skips_ios_but_keeps_common_checks
    commit('SnipSnap/Panel.swift')
    commit('SnipSnapTests/PanelTests.swift')
    commit('docs/notes.md')
    assert_equal %w[mac=true ios=false], selection('pr')
  end
end
