#!/bin/zsh

release_automation_fail() {
    print -u2 "release automation: $1"
    return 1
}

release_automation_brew_tool() {
    local explicit_tool="${1:-}"
    local path_tool=""
    local candidate

    if [[ -n "$explicit_tool" ]]; then
        [[ -x "$explicit_tool" ]] || return 1
        print -r -- "$explicit_tool"
        return 0
    fi
    path_tool="$(command -v brew 2>/dev/null || true)"
    for candidate in "$path_tool" /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        print -r -- "$candidate"
        return 0
    done
    return 1
}

release_automation_tap_name() {
    local tap_repo="$1"
    local owner="${tap_repo%%/*}"
    local repository="${tap_repo#*/}"

    [[ "$owner" != "$tap_repo" && -n "$owner" && "$repository" == homebrew-* &&
       "$repository" != */* && -n "${repository#homebrew-}" ]] || return 1
    print -r -- "$owner/${repository#homebrew-}"
}

release_automation_working_tap_name() {
    local suffix="${1:-}"

    if [[ -z "$suffix" ]]; then
        suffix="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '-')"
    fi
    [[ "$suffix" =~ '^[a-z0-9]+$' ]] || return 1
    print -r -- "snip-snap-release/$suffix"
}

release_automation_tap_checkout() {
    local brew_tool="$1"
    local working_tap_name="$2"
    local tap_repo="$3"
    local tap_checkout
    local tap_status

    release_automation_tap_name "$tap_repo" >/dev/null || return 1
    "$brew_tool" tap "$working_tap_name" "https://github.com/$tap_repo.git" >&2 || return 1
    tap_checkout="$("$brew_tool" --repository "$working_tap_name")" || return 1
    [[ -d "$tap_checkout/.git" ]] || return 1
    git -C "$tap_checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    tap_status="$(git -C "$tap_checkout" status --porcelain)" || return 1
    [[ -z "$tap_status" ]] || return 1
    print -r -- "$tap_checkout"
}

release_automation_remove_working_tap() {
    local brew_tool="$1"
    local working_tap_name="$2"

    "$brew_tool" untap --force "$working_tap_name" >/dev/null 2>&1
}

release_automation_build_number() {
    local run_number="$1"
    local offset="${2:-6}"

    [[ "$run_number" =~ '^[1-9][0-9]*$' ]] || {
        release_automation_fail "workflow run number must be a positive integer"
        return 1
    }
    [[ "$offset" =~ '^(0|[1-9][0-9]*)$' ]] || {
        release_automation_fail "build offset must be a nonnegative integer"
        return 1
    }
    print $(( run_number + offset ))
}

release_automation_beta_tag() {
    local version="$1"
    local build_number="$2"

    release_policy_valid_version "$version" || return 1
    [[ "$build_number" =~ '^[1-9][0-9]*$' ]] || return 1
    print "v$version-beta.$build_number"
}

release_automation_record_name() {
    local version="$1"
    local build_number="$2"
    print "Snip-Snap-$version-beta.$build_number.json"
}

release_automation_remote_tag_commit() {
    local release_repo="$1"
    local tag="$2"
    local refs
    local direct
    local peeled

    refs="$(git ls-remote "https://github.com/$release_repo.git" \
        "refs/tags/$tag" "refs/tags/$tag^{}")" || {
        release_automation_fail "could not inspect $tag"
        return 1
    }
    direct="$(print -r -- "$refs" | /usr/bin/awk \
        -v ref="refs/tags/$tag" '$2 == ref { print $1; exit }')"
    peeled="$(print -r -- "$refs" | /usr/bin/awk \
        -v ref="refs/tags/$tag^{}" '$2 == ref { print $1; exit }')"
    [[ -n "$peeled" || -n "$direct" ]] || {
        release_automation_fail "missing tag $tag"
        return 1
    }
    print "${peeled:-$direct}"
}

release_automation_verify_workflow_run() {
    local record_path="$1"
    local release_repo="$2"
    local expected_commit="$3"
    local run_id
    local run_attempt
    local run_json
    local jobs_json
    local gh_tool="${SNIP_SNAP_GH:-gh}"

    run_id="$(/usr/bin/plutil -extract workflow.runID raw -o - "$record_path")" || {
        release_automation_fail "the beta record has no workflow run ID"
        return 1
    }
    run_attempt="$(/usr/bin/plutil -extract workflow.runAttempt raw -o - "$record_path")" || {
        release_automation_fail "the beta record has no workflow run attempt"
        return 1
    }
    run_json="$("$gh_tool" api "repos/$release_repo/actions/runs/$run_id")" || {
        release_automation_fail "could not read the beta workflow run"
        return 1
    }
    jobs_json="$("$gh_tool" api \
        "repos/$release_repo/actions/runs/$run_id/jobs?filter=all&per_page=100")" || {
        release_automation_fail "could not read the beta workflow jobs"
        return 1
    }
    /usr/bin/ruby -rjson -e '
      run = JSON.parse(ARGV.fetch(0))
      jobs = JSON.parse(ARGV.fetch(1)).fetch("jobs")
      expected_commit = ARGV.fetch(2)
      expected_attempt = Integer(ARGV.fetch(3), 10)
      abort unless run["status"] == "completed"
      abort unless run["conclusion"] == "success"
      abort unless run["head_sha"] == expected_commit
      abort unless run["head_branch"] == "main"
      abort unless ["push", "workflow_dispatch"].include?(run["event"])
      abort unless run["run_attempt"] >= expected_attempt
      required = [
        "Test release source",
        "Build signed Mac beta",
        "Upload internal TestFlight beta",
        "Publish Mac beta channels"
      ]
      abort unless required.all? do |name|
        jobs.any? { |job| job["name"] == name && job["conclusion"] == "success" }
      end
    ' "$run_json" "$jobs_json" "$expected_commit" "$run_attempt" || {
        release_automation_fail "the recorded beta workflow did not pass every release job"
        return 1
    }
}

release_automation_write_record() {
    local output_path="$1"
    local version="$2"
    local build_number="$3"
    local commit="$4"
    local run_url="$5"
    local zip_path="$6"
    local dmg_path="$7"
    local run_id="$8"
    local run_attempt="$9"
    local appcast_path="${10}"
    local beta_tag
    local zip_sha
    local dmg_sha
    local enclosure

    beta_tag="$(release_automation_beta_tag "$version" "$build_number")" || return 1
    [[ "$commit" =~ '^[0-9a-f]{40}$' ]] || {
        release_automation_fail "commit must be a full Git SHA"
        return 1
    }
    [[ "$run_id" =~ '^[1-9][0-9]*$' && "$run_attempt" =~ '^[1-9][0-9]*$' ]] || {
        release_automation_fail "workflow run ID and attempt must be positive integers"
        return 1
    }
    [[ -f "$zip_path" && -f "$dmg_path" ]] || {
        release_automation_fail "release files are missing"
        return 1
    }
    zip_sha="$(/usr/bin/shasum -a 256 "$zip_path" | /usr/bin/awk '{ print $1 }')" || return 1
    dmg_sha="$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{ print $1 }')" || return 1
    typeset -g RELEASE_VERSION="$version"
    typeset -g RELEASE_BUILD_NUMBER="$build_number"
    enclosure="$(release_policy_release_enclosure "$appcast_path")" || {
        release_automation_fail "generated appcast has no matching enclosure"
        return 1
    }

    /usr/bin/ruby -rjson -e '
      output, version, build, commit, run_url, run_id, run_attempt, tag,
        zip_name, zip_sha, dmg_name, dmg_sha, enclosure = ARGV
      signature = enclosure[/\bsparkle:edSignature="([^"]+)"/, 1]
      length = enclosure[/\blength="([0-9]+)"/, 1]
      url = enclosure[/\burl="([^"]+)"/, 1]
      abort unless signature && length && url
      record = {
        "schemaVersion" => 2,
        "version" => version,
        "build" => Integer(build, 10),
        "commit" => commit,
        "runURL" => run_url,
        "workflow" => {
          "runID" => Integer(run_id, 10),
          "runAttempt" => Integer(run_attempt, 10),
          "testResult" => "passed",
          "macSigningResult" => "verified",
          "macNotarizationResult" => "accepted",
          "testFlightUploadResult" => "uploaded"
        },
        "betaTag" => tag,
        "zip" => {
          "name" => File.basename(zip_name),
          "sha256" => zip_sha,
          "length" => Integer(length, 10),
          "url" => url,
          "sparkleEdSignature" => signature
        },
        "dmg" => { "name" => File.basename(dmg_name), "sha256" => dmg_sha }
      }
      File.write(output, JSON.pretty_generate(record) + "\n")
    ' "$output_path" "$version" "$build_number" "$commit" "$run_url" \
        "$run_id" "$run_attempt" "$beta_tag" "$zip_path" "$zip_sha" \
        "$dmg_path" "$dmg_sha" "$enclosure"
}

release_automation_verify_record() {
    local record_path="$1"
    local version="$2"
    local build_number="$3"
    local zip_path="$4"
    local dmg_path="$5"
    local expected_commit="${6:-}"

    [[ -f "$record_path" && -f "$zip_path" && -f "$dmg_path" ]] || {
        release_automation_fail "record or release files are missing"
        return 1
    }
    /usr/bin/ruby -rjson -rdigest -e '
      record_path, version, build, zip_path, dmg_path, expected_commit = ARGV
      record = JSON.parse(File.read(record_path))
      abort unless record["schemaVersion"] == 2
      abort unless record["version"] == version
      abort unless record["build"] == Integer(build, 10)
      abort unless expected_commit.empty? || record["commit"] == expected_commit
      abort unless record.dig("zip", "name") == File.basename(zip_path)
      abort unless record.dig("dmg", "name") == File.basename(dmg_path)
      abort unless record.dig("zip", "sha256") == Digest::SHA256.file(zip_path).hexdigest
      abort unless record.dig("dmg", "sha256") == Digest::SHA256.file(dmg_path).hexdigest
      abort unless record.dig("zip", "length") == File.size(zip_path)
      abort unless record.dig("zip", "url").is_a?(String) && !record.dig("zip", "url").empty?
      abort unless record.dig("zip", "sparkleEdSignature").is_a?(String) &&
        !record.dig("zip", "sparkleEdSignature").empty?
      workflow = record["workflow"]
      abort unless workflow.is_a?(Hash)
      abort unless workflow["runID"].is_a?(Integer) && workflow["runID"] > 0
      abort unless workflow["runAttempt"].is_a?(Integer) && workflow["runAttempt"] > 0
      abort unless workflow["testResult"] == "passed"
      abort unless workflow["macSigningResult"] == "verified"
      abort unless workflow["macNotarizationResult"] == "accepted"
      abort unless workflow["testFlightUploadResult"] == "uploaded"
    ' "$record_path" "$version" "$build_number" "$zip_path" "$dmg_path" "$expected_commit" || {
        release_automation_fail "release record does not match the tested files"
        return 1
    }
}

release_automation_verify_record_appcast() {
    local record_path="$1"
    local appcast_path="$2"
    local version="$3"
    local build_number="$4"
    local channel="${5:-beta}"
    local enclosure

    typeset -g RELEASE_VERSION="$version"
    typeset -g RELEASE_BUILD_NUMBER="$build_number"
    enclosure="$(release_policy_release_enclosure "$appcast_path")" || {
        release_automation_fail "appcast has no recorded release enclosure"
        return 1
    }
    /usr/bin/ruby -rjson -e '
      record = JSON.parse(File.read(ARGV.fetch(0)))
      enclosure = ARGV.fetch(1)
      channel = ARGV.fetch(2)
      expected_url = record.dig("zip", "url")
      if channel == "default"
        expected_url = expected_url.sub(record.fetch("betaTag"), "v#{record.fetch("version")}")
      else
        abort unless channel == "beta"
      end
      actual = {
        "length" => Integer(enclosure[/\blength="([0-9]+)"/, 1], 10),
        "url" => enclosure[/\burl="([^"]+)"/, 1],
        "sparkleEdSignature" => enclosure[/\bsparkle:edSignature="([^"]+)"/, 1]
      }
      abort unless actual.values.none?(&:nil?)
      abort unless actual["length"] == record.dig("zip", "length")
      abort unless actual["sparkleEdSignature"] == record.dig("zip", "sparkleEdSignature")
      abort unless actual["url"] == expected_url
    ' "$record_path" "$enclosure" "$channel" || {
        release_automation_fail "appcast does not match the beta record"
        return 1
    }
}

release_automation_require_appcast_channel() {
    local appcast_path="$1"
    local version="$2"
    local build_number="$3"
    local expected_channel="$4"

    /usr/bin/ruby -e '
      path, version, build, expected = ARGV
      xml = File.read(path)
      item = xml.scan(/<item\b.*?<\/item>/m).find do |candidate|
        candidate.match?(/sparkle:version(?:="|>)#{Regexp.escape(build)}(?:"|<)/) &&
          candidate.match?(/sparkle:shortVersionString(?:="|>)#{Regexp.escape(version)}(?:"|<)/)
      end
      abort "appcast item not found" unless item
      channel = item[/<sparkle:channel>([^<]+)<\/sparkle:channel>/, 1]
      abort "appcast item channel does not match #{expected}" unless
        expected == "default" ? channel.nil? : channel == expected
    ' "$appcast_path" "$version" "$build_number" "$expected_channel" || {
        release_automation_fail "could not verify appcast item channel"
        return 1
    }
}

release_automation_promote_appcast() {
    local input_path="$1"
    local output_path="$2"
    local version="$3"
    local build_number="$4"
    local beta_tag="$5"
    local stable_tag="v$version"

    /usr/bin/ruby -e '
      input, output, version, build, beta_tag, stable_tag = ARGV
      xml = File.read(input)
      matches = 0
      beta_notes = "Snip-Snap-#{version}-beta.#{build}.md"
      stable_notes = "Snip-Snap-#{version}.md"
      promoted = xml.gsub(/<item\b.*?<\/item>/m) do |item|
        matching = item.match?(/sparkle:version(?:="|>)#{Regexp.escape(build)}(?:"|<)/) &&
          item.match?(/sparkle:shortVersionString(?:="|>)#{Regexp.escape(version)}(?:"|<)/)
        next item unless matching
        abort unless item.include?("<sparkle:channel>beta</sparkle:channel>")
        matches += 1
        item
          .sub(/\s*<sparkle:channel>beta<\/sparkle:channel>\s*/, "\n")
          .gsub(beta_tag, stable_tag)
          .gsub(beta_notes, stable_notes)
      end
      abort unless matches == 1
      File.write(output, promoted)
    ' "$input_path" "$output_path" "$version" "$build_number" "$beta_tag" "$stable_tag" || {
        release_automation_fail "could not promote the beta appcast item"
        return 1
    }
}
