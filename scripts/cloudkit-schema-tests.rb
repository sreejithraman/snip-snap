#!/usr/bin/env ruby
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'

class CloudKitSchemaTests < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  COMPARATOR = File.join(__dir__, 'cloudkit-schema.rb')

  def compare(expected, deployed)
    Dir.mktmpdir('snip-snap-schema-test') do |dir|
      live = File.join(dir, 'live.ckdb')
      production = File.join(dir, 'production.ckdb')
      File.write(live, expected)
      File.write(production, deployed)
      Open3.capture3('/usr/bin/ruby', COMPARATOR, live, production)
    end
  end

  def test_reports_missing_live_color_preset_even_when_legacy_color_exists
    out, err, status = compare(
      'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES);',
      'DEFINE SCHEMA RECORD TYPE List (color ENCRYPTED BYTES);'
    )
    refute status.success?
    assert_includes out + err, 'missing field List.colorPreset (expected ENCRYPTED BYTES)'
  end
  def test_retains_retired_fields_and_handles_export_system_fields_indexes_and_grants
    expected = 'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES);'
    deployed = <<~SCHEMA
      DEFINE SCHEMA
      /* Production retains old clients' fields. */
      RECORD TYPE "List" (
        "___recordID" REFERENCE QUERYABLE,
        "colorPreset" ENCRYPTED BYTES,
        color ENCRYPTED BYTES, // retired
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
      );
      RECORD TYPE Users (roles LIST<INT64>);
    SCHEMA
    out, err, status = compare(expected, deployed)
    assert status.success?, out + err
    assert_includes out, 'extra deployed fields and record types retained'
  end

  def test_reports_all_type_encryption_and_missing_record_problems
    out, err, status = compare(
      'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES, desiredName ENCRYPTED STRING); RECORD TYPE Snip (text ENCRYPTED STRING);',
      'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED STRING, desiredName STRING);'
    )
    refute status.success?
    assert_includes out + err, 'List.colorPreset: expected ENCRYPTED BYTES, Production has ENCRYPTED STRING'
    assert_includes out + err, 'List.desiredName: expected ENCRYPTED STRING, Production has STRING'
    assert_includes out + err, 'missing record type Snip'
    assert_includes out + err, 'missing field Snip.text'
  end

  def test_rejects_empty_truncated_duplicate_and_unrecognized_exports
    live = 'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES);'
    ['', 'DEFINE SCHEMA',
     'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES',
     'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES, colorPreset BYTES);',
     'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES); RECORD TYPE List (colorPreset ENCRYPTED BYTES);',
     'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES MYSTERY);',
     'DEFINE SCHEMA RECORD TYPE List (colorPreset ENCRYPTED BYTES); /* unclosed'].each do |export|
      _out, err, status = compare(live, export)
      assert_equal 2, status.exitstatus, err
    end
  end


  def with_preflight_tools
    Dir.mktmpdir('snip-snap-preflight-test') do |dir|
      tools = File.join(dir, 'tools')
      Dir.mkdir(tools)
      trace = File.join(dir, 'trace')
      File.write(File.join(tools, 'swift'), <<~SH)
        #!/bin/zsh
        print -r -- "swift $*" >> "$PREFLIGHT_TEST_TRACE"
        case "${PREFLIGHT_TEST_CODEC_RESULT:-passed}" in
          passed|skipped)
            print -r -- "Test Case '-[SnipSnapCloudTests.CloudKitSchemaContractTests testCheckedSchemaMatchesEveryRuntimeRecordFieldAndStorageClass]' ${PREFLIGHT_TEST_CODEC_RESULT:-passed}."
            ;;
          unmatched) print 'warning: No matching test cases were run' ;;
          empty) ;;
        esac
        exit "${PREFLIGHT_TEST_CODEC_EXIT:-0}"
      SH
      File.write(File.join(tools, 'xcrun'), <<~SH)
        #!/bin/zsh
        print -r -- "xcrun $*" >> "$PREFLIGHT_TEST_TRACE"
        [[ "$1 $2" == 'cktool export-schema' ]] || exit 7
        [[ "${PREFLIGHT_TEST_EXPORT_EXIT:-0}" == 0 ]] || exit "$PREFLIGHT_TEST_EXPORT_EXIT"
        while (( $# )); do
          if [[ "$1" == --output-file ]]; then
            cp "$PREFLIGHT_TEST_SCHEMA" "$2"
            exit 0
          fi
          shift
        done
        exit 8
      SH
      File.chmod(0755, File.join(tools, 'swift'), File.join(tools, 'xcrun'))
      env = {
        'PATH' => "#{tools}:/usr/bin:/bin",
        'SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED' => 'NO',
        'SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID' => 'EXAMPLE_TEAM',
        'SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID' => 'iCloud.org.example.snipsnap',
        'SNIP_SNAP_CLOUDKIT_PREFLIGHT_REPORT_DIR' => File.join(dir, 'reports'),
        'PREFLIGHT_TEST_TRACE' => trace,
        'PREFLIGHT_TEST_SCHEMA' => File.join(ROOT, 'CloudKit/SnipSnap.ckdb')
      }
      yield dir, trace, env
    end
  end

  def run_preflight(env, *args)
    Open3.capture3(env, File.join(__dir__, 'cloudkit-release-preflight.sh'), *args)
  end

  def report_in(dir)
    File.read(Dir.glob(File.join(dir, 'reports/*/report.txt')).fetch(0))
  end

  def test_live_preflight_exports_only_production_and_saves_evidence
    with_preflight_tools do |dir, trace, env|
      out, err, status = run_preflight(env)
      assert status.success?, out + err
      commands = File.read(trace)
      assert_includes commands, '--filter CloudKitSchemaContractTests'
      assert_includes commands, '--environment production'
      refute_match(/import|deploy|reset|create-record/, commands)
      assert_equal 1, Dir.glob(File.join(dir, 'reports/*/Production.ckdb')).length
      assert_includes report_in(dir), 'PASS: live fields match deployed Production'
    end
  end

  def test_disabled_release_gate_needs_no_credentials_and_invokes_no_tools
    with_preflight_tools do |dir, trace, env|
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID'] = nil
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID'] = nil
      out, err, status = run_preflight(env, '--if-enabled')
      assert status.success?, out + err
      refute File.exist?(trace)
      refute Dir.exist?(File.join(dir, 'reports'))
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED'] = 'unexpected'
      _out, _err, status = run_preflight(env, '--if-enabled')
      refute status.success?
    end
  end

  def test_codec_failure_stops_before_contacting_cloudkit
    with_preflight_tools do |dir, trace, env|
      env['PREFLIGHT_TEST_CODEC_EXIT'] = '5'
      out, err, status = run_preflight(env)
      refute status.success?
      assert_includes out + err, 'live codec/schema contract failed'
      refute_includes File.read(trace), 'cktool'
      assert_includes report_in(dir), 'FAIL'
    end
  end

  def test_export_auth_failure_stops_and_preserves_failure_evidence
    with_preflight_tools do |dir, _trace, env|
      env['PREFLIGHT_TEST_EXPORT_EXIT'] = '5'
      out, err, status = run_preflight(env)
      refute status.success?
      assert_includes out + err, 'Production export failed'
      assert_includes report_in(dir), 'FAIL'
      refute_includes report_in(dir), 'PASS: live fields match deployed Production'
    end
  end

  def test_opted_in_release_gate_blocks_deployment_drift
    with_preflight_tools do |dir, _trace, env|
      deployed = File.join(dir, 'deployed.ckdb')
      File.write(deployed, File.read(env.fetch('PREFLIGHT_TEST_SCHEMA')).sub('colorPreset ENCRYPTED BYTES', 'color ENCRYPTED BYTES'))
      env['PREFLIGHT_TEST_SCHEMA'] = deployed
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED'] = 'YES'
      out, err, status = run_preflight(env, '--if-enabled')
      refute status.success?
      assert_includes out + err, 'missing field List.colorPreset'
      assert_includes report_in(dir), 'missing field List.colorPreset'
      assert_includes report_in(dir), 'FAIL'
    end
  end

  def signed_mac_zip(dir, env, containers: ['iCloud.org.example.snipsnap'], environment: 'Production', runtime_container: 'iCloud.org.example.snipsnap')
    app = File.join(dir, 'Snip Snap.app')
    contents = File.join(app, 'Contents')
    FileUtils.mkdir_p(contents)
    File.write(File.join(contents, 'embedded.provisionprofile'), 'fixture profile')
    info = File.join(contents, 'Info.plist')
    info_values = { 'CFBundleIdentifier' => 'org.example.snipsnap' }
    info_values['SnipSnapCloudKitContainerIdentifier'] = runtime_container unless runtime_container.nil?
    File.write(info, info_values.to_json)
    system('/usr/bin/plutil', '-convert', 'xml1', info, exception: true)
    signed = {
      'com.apple.developer.team-identifier' => 'EXAMPLE_TEAM',
      'com.apple.developer.icloud-container-identifiers' => containers,
      'com.apple.developer.icloud-container-environment' => environment,
      'com.apple.developer.icloud-services' => ['CloudKit'],
      'com.apple.developer.aps-environment' => 'production'
    }
    entitlement_path = File.join(dir, 'signed-entitlements.plist')
    File.write(entitlement_path, signed.to_json)
    system('/usr/bin/plutil', '-convert', 'xml1', entitlement_path, exception: true)
    profile_path = File.join(dir, 'profile.plist')
    profile = {
      'TeamIdentifier' => ['EXAMPLE_TEAM'],
      'ApplicationIdentifierPrefix' => ['EXAMPLE_PREFIX'],
      'ExpirationDate' => '2099-01-01T00:00:00Z',
      'Entitlements' => signed.merge('com.apple.application-identifier' => 'EXAMPLE_PREFIX.org.example.snipsnap')
    }
    File.write(profile_path, profile.to_json)
    system('/usr/bin/plutil', '-convert', 'xml1', profile_path, exception: true)
    codesign = File.join(dir, 'codesign')
    File.write(codesign, <<~SH)
      #!/bin/zsh
      print -r -- "codesign $*" >> "$PREFLIGHT_TEST_TRACE"
      [[ "${PREFLIGHT_TEST_SIGNATURE_EXIT:-0}" == 0 ]] || exit "$PREFLIGHT_TEST_SIGNATURE_EXIT"
      [[ "$1" != -d ]] || cat "$PREFLIGHT_TEST_ENTITLEMENTS"
    SH
    security = File.join(dir, 'security')
    File.write(security, <<~SH)
      #!/bin/zsh
      cat "$PREFLIGHT_TEST_PROFILE"
    SH
    File.chmod(0755, codesign, security)
    env.merge!(
      'SNIP_SNAP_CODESIGN' => codesign,
      'SNIP_SNAP_SECURITY' => security,
      'PREFLIGHT_TEST_ENTITLEMENTS' => entitlement_path,
      'PREFLIGHT_TEST_PROFILE' => profile_path
    )
    zip = File.join(dir, 'release.zip')
    system('/usr/bin/ditto', '-c', '-k', '--keepParent', app, zip, exception: true)
    zip
  end

  def test_mac_release_target_comes_from_verified_signed_zip
    with_preflight_tools do |dir, trace, env|
      zip = signed_mac_zip(dir, env)
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_TEAM_ID'] = nil
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID'] = nil
      out, err, status = run_preflight(env, '--mac-release-zip', zip)
      assert status.success?, out + err
      assert_includes File.read(trace), 'codesign --verify --deep --strict'
      assert_includes File.read(trace), '--team-id EXAMPLE_TEAM --container-id iCloud.org.example.snipsnap'
      assert_empty Dir.glob(File.join(dir, 'reports/*/mac-release'))
    end
  end

  def test_mac_release_rejects_wrong_target_override_before_cloudkit_access
    with_preflight_tools do |dir, trace, env|
      zip = signed_mac_zip(dir, env)
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID'] = 'wrong-container'
      out, err, status = run_preflight(env, '--mac-release-zip', zip)
      refute status.success?
      assert_includes out + err, 'configured preflight container differs from signed Mac release'
      assert_empty Dir.glob(File.join(dir, 'reports/*/mac-release'))
      refute_includes File.read(trace), 'cktool'
      refute_includes File.read(trace), 'swift'
    end
  end

  def test_mac_release_rejects_missing_or_mismatched_runtime_container
    [nil, 'wrong-container'].each do |runtime|
      with_preflight_tools do |dir, trace, env|
        zip = signed_mac_zip(dir, env, runtime_container: runtime)
        out, err, status = run_preflight(env, '--mac-release-zip', zip)
        refute status.success?
        assert_includes out + err, 'runtime CloudKit container'
        refute_includes File.read(trace), 'cktool'
      end
    end
  end

  def test_mac_release_rejects_invalid_signature_and_nonproduction_target
    with_preflight_tools do |dir, trace, env|
      zip = signed_mac_zip(dir, env, environment: 'Development')
      out, err, status = run_preflight(env, '--mac-release-zip', zip)
      refute status.success?
      assert_includes out + err, 'Production environment'
      refute_includes File.read(trace), 'cktool'
      env['PREFLIGHT_TEST_SIGNATURE_EXIT'] = '5'
      out, err, status = run_preflight(env, '--mac-release-zip', zip)
      refute status.success?
      assert_includes out + err, 'signature verification failed'
      assert_empty Dir.glob(File.join(dir, 'reports/*/mac-release'))
    end
  end

  def test_mac_beta_publisher_blocks_before_publishing_schema_drift
    with_preflight_tools do |dir, trace, env|
      zip = signed_mac_zip(dir, env)
      repo = File.join(dir, 'release-repo')
      scripts = File.join(repo, 'scripts')
      FileUtils.mkdir_p([scripts, File.join(repo, 'CloudKit')])
      %w[publish-beta.sh release-automation.sh signing-policy.sh cloudkit-release-preflight.sh cloudkit-schema.rb].each do |name|
        FileUtils.cp(File.join(__dir__, name), File.join(scripts, name))
      end
      baseline = File.read(File.join(ROOT, 'CloudKit/SnipSnap.ckdb'))
      File.write(File.join(repo, 'CloudKit/SnipSnap.ckdb'), baseline)
      deployed = File.join(dir, 'deployed.ckdb')
      File.write(deployed, baseline.sub('colorPreset ENCRYPTED BYTES', 'color ENCRYPTED BYTES'))
      env['PREFLIGHT_TEST_SCHEMA'] = deployed
      File.write(File.join(scripts, 'release-policy.sh'), <<~SH)
        release_policy_preflight() { RELEASE_VERSION=1.2.3; RELEASE_BUILD_NUMBER=123; }
        release_policy_verify_checksum() { :; }
        release_policy_valid_version() { :; }
        release_policy_valid_build_number() { :; }
      SH
      release_dir = File.join(dir, 'artifacts')
      FileUtils.mkdir_p(release_dir)
      FileUtils.cp(zip, File.join(release_dir, 'Snip-Snap-1.2.3.zip'))
      %w[Snip-Snap-1.2.3.dmg Snip-Snap-1.2.3.zip.sha256 Snip-Snap-1.2.3.dmg.sha256].each do |name|
        File.write(File.join(release_dir, name), 'fixture')
      end
      git_tool = File.join(dir, 'git')
      File.write(git_tool, "#!/bin/zsh\nprint example-commit\n")
      File.chmod(0755, git_tool)
      # The publisher hardens PATH; stub its public preflight command boundary.
      File.write(File.join(scripts, 'cloudkit-release-preflight.sh'), <<~SH)
        #!/bin/zsh
        print -r -- "preflight $*" >> "$PREFLIGHT_TEST_TRACE"
        print -u2 'CloudKit preflight: missing field List.colorPreset (expected ENCRYPTED BYTES)'
        exit 1
      SH
      File.chmod(0755, File.join(scripts, 'cloudkit-release-preflight.sh'))
      env['SNIP_SNAP_GIT'] = git_tool
      env['SNIP_SNAP_RELEASE_DIR'] = release_dir
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED'] = 'YES'
      out, err, status = Open3.capture3(env, File.join(scripts, 'publish-beta.sh'), '--build-number', '123')
      refute status.success?
      assert_includes out + err, 'missing field List.colorPreset'
      assert_includes File.read(trace), "preflight --if-enabled --mac-release-zip #{release_dir}/Snip-Snap-1.2.3.zip"
    end
  end

  def test_empty_unmatched_and_skipped_codec_runs_do_not_prove_schema_contract
    %w[empty unmatched skipped].each do |result|
      with_preflight_tools do |dir, trace, env|
        env['PREFLIGHT_TEST_CODEC_RESULT'] = result
        out, err, status = run_preflight(env)
        refute status.success?
        assert_includes out + err, 'live codec/schema contract did not run and pass'
        refute_includes File.read(trace), 'cktool'
        assert_includes report_in(dir), 'FAIL'
      end
    end
  end

  def test_testflight_upload_checks_its_resolved_target_and_stops_before_upload
    with_preflight_tools do |dir, trace, env|
      repo = File.join(dir, 'release-repo')
      scripts = File.join(repo, 'scripts')
      FileUtils.mkdir_p([scripts, File.join(repo, 'Config'), File.join(repo, 'CloudKit')])
      %w[testflight.sh cloudkit-release-preflight.sh cloudkit-schema.rb].each do |name|
        FileUtils.cp(File.join(__dir__, name), File.join(scripts, name))
      end
      File.write(File.join(repo, 'Config/TestFlight.entitlements'), 'fixture')
      baseline = File.read(File.join(ROOT, 'CloudKit/SnipSnap.ckdb'))
      File.write(File.join(repo, 'CloudKit/SnipSnap.ckdb'), baseline)
      deployed = File.join(dir, 'deployed.ckdb')
      File.write(deployed, baseline.sub('colorPreset ENCRYPTED BYTES', 'color ENCRYPTED BYTES'))
      env['PREFLIGHT_TEST_SCHEMA'] = deployed
      File.write(File.join(scripts, 'release-policy.sh'), <<~SH)
        release_policy_load_release() { RELEASE_VERSION=1.2.3; RELEASE_BUILD_NUMBER=123; }
        release_policy_require_project_versions() { :; }
      SH
      File.write(File.join(scripts, 'signing-policy.sh'), <<~SH)
        signing_policy_capture_build_settings() { :; }
        signing_policy_preflight() { :; }
        signing_policy_resolve_setting() {
          case "$2" in
            DEVELOPMENT_TEAM) print EXAMPLE_RESOLVED_TEAM ;;
            SNIP_SNAP_CLOUDKIT_CONTAINER_IDENTIFIER) print iCloud.org.example.snipsnap ;;
            *) print example ;;
          esac
        }
      SH
      File.write(File.join(scripts, 'testflight-policy.sh'), <<~SH)
        testflight_policy_verify_source_record() { :; }
        testflight_policy_verify_archive() { :; }
      SH
      File.open(File.join(scripts, 'release-policy.sh'), 'a') do |file|
        file.puts('release_policy_require_source() { :; }')
      end
      archive = File.join(dir, 'archive')
      app_dir = File.join(archive, 'Products/Applications/Snip Snap iOS.app')
      FileUtils.mkdir_p(app_dir)
      File.write(File.join(app_dir, 'Info.plist'), { 'SnipSnapCloudKitContainerIdentifier' => 'iCloud.org.example.snipsnap' }.to_json)
      system('/usr/bin/plutil', '-convert', 'xml1', File.join(app_dir, 'Info.plist'), exception: true)
      env['SNIP_SNAP_CONFIRM_TESTFLIGHT_UPLOAD'] = 'YES'
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_ENABLED'] = 'YES'
      env['SNIP_SNAP_CLOUDKIT_PREFLIGHT_CONTAINER_ID'] = 'incorrect-target'
      env['SNIP_SNAP_TESTFLIGHT_ENTITLEMENTS'] = File.join(repo, 'Config/TestFlight.entitlements')
      out, err, status = Open3.capture3(env, File.join(scripts, 'testflight.sh'), 'upload', '--archive-path', archive, '--build-number', '123')
      refute status.success?
      assert_includes out + err, 'missing field List.colorPreset'
      assert_includes File.read(trace), '--team-id EXAMPLE_RESOLVED_TEAM --container-id iCloud.org.example.snipsnap'
      refute File.exist?(File.join(repo, 'artifacts/testflight-1.2.3-123/upload.log'))
      [nil, 'wrong-container'].each do |runtime|
        File.write(trace, '')
        values = runtime ? { 'SnipSnapCloudKitContainerIdentifier' => runtime } : {}
        File.write(File.join(app_dir, 'Info.plist'), values.to_json)
        system('/usr/bin/plutil', '-convert', 'xml1', File.join(app_dir, 'Info.plist'), exception: true)
        out, err, status = Open3.capture3(env, File.join(scripts, 'testflight.sh'), 'upload', '--archive-path', archive, '--build-number', '123')
        refute status.success?
        assert_includes out + err, 'runtime CloudKit container'
        refute_includes File.read(trace), 'cktool'
      end
    end
  end

end
