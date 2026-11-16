# This reads sanitized evidence only. It never opens an account, signing key, or database.
require 'json'
require 'time'

begin
  directory, revision = ARGV
  manifest = JSON.parse(File.read(File.join(directory, 'manifest.json')))
  required = %w[baseline setup 9-capability 1-3-4-5-one-stale 2-three-stale 3-all-atomic-events
                6-unchanged-companion 7-failed-ordinary 7-failed-atomic
                8-fetch-0 8-fetch-1 8-fetch-2 setup-planner-3 10-planner-3
                setup-planner-5 10-planner-5]
  raise 'source revision mismatch' unless revision&.match?(/\A[0-9a-f]{40}\z/) &&
    manifest['sourceRevision'] == revision && manifest['harnessRevision'] == revision
  raise 'missing account fingerprint' unless manifest['accountFingerprint']&.match?(/\A[0-9a-f]{64}\z/)
  run_id = manifest.fetch('runID').downcase
  raise 'invalid run identity' unless run_id.match?(/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/)
  expected = %w[metadata payload planner3-metadata planner3-payload planner5-metadata planner5-payload].map do |suffix|
    "snipsnap-contract-#{run_id}-#{suffix}"
  end
  raise 'wrong synthetic zones' unless manifest['zones'] == expected
  cleanup = manifest.fetch('cleanup')
  raise 'unresolved cleanup' unless cleanup.keys.sort == expected.sort && cleanup.values.all? { |v| v == 'verified-absent' }
  outcomes = manifest.fetch('cleanupOutcomes')
  raise 'missing exact-zone cleanup outcomes' unless outcomes.keys.sort == expected.sort
  outcomes.each do |zone, outcome|
    raise 'inconsistent cleanup outcome' unless outcome['zoneName'] == zone && outcome['verifiedAbsent'] == true
    attempts = outcome.fetch('attempts')
    raise 'missing or unbounded cleanup attempts' unless attempts.is_a?(Array) && (2..6).cover?(attempts.length)
    raise 'invalid cleanup attempt' unless attempts.all? { |a| (1..3).cover?(a['number']) && %w[delete read].include?(a['operation']) && a['result'].is_a?(String) }
    raise 'cleanup absence not observed' unless attempts.last['operation'] == 'read' && attempts.last['result'] == 'absent'
  end
  results = manifest.fetch('results')
  raise 'missing/failed phase' unless required.all? { |key| results[key] == 'pass' }
  [3, 5].each do |count|
    raise 'missing measured planner cost' unless results["10-cost-#{count}"]&.start_with?(
      "atomic-provider-batches=1; metadata-member-saves=#{count}; all-provider-batches=")
  end
  start = Time.iso8601(manifest.fetch('startedAt'))
  work = Time.iso8601(manifest.fetch('workDeadline'))
  cleanup_deadline = Time.iso8601(manifest.fetch('cleanupDeadline'))
  raise 'cleanup reserve changed' unless work - start == 1800 && cleanup_deadline - start == 2400
  trace = JSON.parse(File.read(File.join(directory, 'sdk-trace.json')))
  raise 'missing real SDK trace' unless trace.is_a?(Array) && !trace.empty? && trace.size <= 10_000
  raise 'trace sequence missing' unless trace.map { |entry| entry['sequence'] } == (0...trace.size).to_a
  %w[1-3-4-5-one-stale 2-three-stale 6-unchanged-companion 7-failed-ordinary 7-failed-atomic 10-planner-3 10-planner-5].each do |phase|
    rows = trace.select { |entry| entry['phase'] == phase }
    raise 'missing provider/event observation' unless rows.any? { |e| e['kind'] == 'provider-batch' } &&
      rows.any? { |e| e['kind'] == 'sent-event-before' }
  end
rescue StandardError => error
  # Values and paths are deliberately excluded from diagnostics.
  reason = error.instance_of?(RuntimeError) ? error.message : 'unreadable or invalid sanitized artifact'
  warn "Cloud contract evidence rejected: #{reason}"
  exit 1
end
