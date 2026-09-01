#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${1:-${script_dir:h}}"

git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    print -u2 "tracked-input policy: not a Git worktree"
    exit 1
}

/usr/bin/ruby - "$repo_dir" <<'RUBY'
repo = ARGV.fetch(0)
paths = IO.popen(["git", "-C", repo, "ls-files", "-z"], &:read).split("\0")
violations = []

def clear_fake_value?(value)
  value.match?(/\A(?:FAKE|EXAMPLE|PLACEHOLDER|YOUR_)[A-Z0-9_-]*\z/i)
end

paths.each do |path|
  full_path = File.join(repo, path)
  next unless File.file?(full_path)

  if path.match?(/\.(?:p8|p12|mobileprovision)\z/i)
    violations << [path, 1, "Apple signing credential file"]
    next
  end

  begin
    contents = File.binread(full_path)
    next if contents.include?("\0")
    contents.force_encoding(Encoding::UTF_8)
    next unless contents.valid_encoding?
  rescue SystemCallError
    next
  end

  if contents.match?(/-----BEGIN (?:(?:OPENSSH|DSA|EC|RSA) )?PRIVATE KEY-----/)
    violations << [path, 1, "private key"]
    next
  end

  contents.each_line.with_index(1) do |line, line_number|
    rules = []

    rules << "personal home path" if line.match?(%r{/(?:Users|home)/[A-Za-z0-9._-]+/})

    build_input = path.end_with?(".xcconfig", ".entitlements", ".plist") ||
      path.end_with?("project.pbxproj")
    app_group_values = line.scan(/\bgroup\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b/)
    public_app_groups = [
      "group.org.example.snipsnap",
      "group.org.example.snipsnap.dev"
    ]
    if build_input && app_group_values.any? { |value| !public_app_groups.include?(value) }
      rules << "non-placeholder App Group ID"
    end

    cloudkit_values = line.scan(/\biCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\b/)
    public_cloudkit_containers = ["iCloud.org.example.snipsnap"]
    if cloudkit_values.any? { |value| !public_cloudkit_containers.include?(value) }
      rules << "non-placeholder CloudKit container ID"
    end

    team_context = line.match?(/DEVELOPMENT_TEAM|teamID|TeamIdentifier|Developer ID Application/i)
    team_values = line.scan(/\b[A-Z0-9]{10}\b/)
    rules << "Apple team ID" if team_context && team_values.any? { |value| !clear_fake_value?(value) }

    profile_value = line[/\bPROVISIONING_PROFILE(?:_SPECIFIER)?\s*=\s*["']?([^;"'\s#]+)/, 1]
    rules << "provisioning profile" if profile_value && !clear_fake_value?(profile_value)

    identity_value = line[/\bSNIP_SNAP_SIGNING_IDENTITY\s*=\s*["']?([^;"'\s#]+)/, 1]
    code_sign_value = line[/\bCODE_SIGN_IDENTITY\s*=\s*["']?([^;"'#]+)/, 1]&.strip
    code_sign_identity = code_sign_value &&
      (code_sign_value.include?(":") || code_sign_value.match?(/\b[0-9a-f]{40}\b/i))
    rules << "signing identity" if
      (identity_value && !identity_value.start_with?("$") && !clear_fake_value?(identity_value)) ||
      (code_sign_identity && !clear_fake_value?(code_sign_value))

    device_context = line.match?(/\b(?:DEVICE|SIMULATOR)[A-Z_]*(?:ID|UDID)\b|destination.*\bid=/i)
    machine_id = line.match?(/\b[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\b/i) ||
      line.match?(/\b[0-9a-f]{40}\b/i)
    rules << "device or Simulator ID" if device_context && machine_id

    rules.uniq.each do |rule|
      violations << [path, line_number, rule]
    end
  end
end

if violations.any?
  violations.each do |path, line_number, rule|
    warn "tracked-input policy: #{path}:#{line_number} contains a forbidden #{rule}"
  end
  exit 1
end

puts "Tracked build inputs contain no maintainer signing or machine values."
RUBY
