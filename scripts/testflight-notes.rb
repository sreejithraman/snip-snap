#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the TestFlight "What's New" text for one exact iOS build.
require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module TestFlightNotes
  API_HOST = "api.appstoreconnect.apple.com"
  API_BASE = "https://#{API_HOST}"
  LOCALE = "en-US"
  MAX_NOTES_LENGTH = 4_000
  DEFAULT_TIMEOUT_SECONDS = 15 * 60
  DEFAULT_POLL_SECONDS = 15
  MAX_PAGES = 100

  class Error < StandardError; end

  def self.base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  class TokenProvider
    def initialize(key_path:, key_id:, issuer_id:, now: -> { Time.now.to_i })
      @key = OpenSSL::PKey.read(File.binread(key_path))
      unless @key.is_a?(OpenSSL::PKey::EC) && %w[prime256v1 secp256r1].include?(@key.group.curve_name)
        raise Error, "Apple API key is not an ES256 P-256 private key"
      end
      @key_id = key_id
      @issuer_id = issuer_id
      @now = now
    rescue Errno::ENOENT
      raise Error, "Apple API key file is missing"
    rescue OpenSSL::PKey::PKeyError
      raise Error, "Apple API key file is not a valid private key"
    end

    # Create a short-lived token per request. App Store Connect uses the raw
    # 64-byte JOSE ECDSA signature, while OpenSSL returns ASN.1 DER.
    def call
      issued_at = @now.call
      encoded_header = TestFlightNotes.base64url(JSON.generate(alg: "ES256", kid: @key_id, typ: "JWT"))
      encoded_payload = TestFlightNotes.base64url(JSON.generate(iss: @issuer_id, iat: issued_at, exp: issued_at + 1_190, aud: "appstoreconnect-v1"))
      signing_input = "#{encoded_header}.#{encoded_payload}"
      der_signature = @key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))
      "#{signing_input}.#{TestFlightNotes.base64url(self.class.der_to_jose(der_signature))}"
    end

    def self.der_to_jose(signature)
      sequence = OpenSSL::ASN1.decode(signature)
      values = sequence.value
      raise Error, "Apple API key produced an invalid ECDSA signature" unless sequence.is_a?(OpenSSL::ASN1::Sequence) && values.length == 2

      values.map do |integer|
        bytes = integer.value.to_s(2)
        raise Error, "Apple API key produced an invalid ECDSA signature" if bytes.bytesize > 32

        bytes.rjust(32, "\0")
      end.join
    rescue OpenSSL::ASN1::ASN1Error
      raise Error, "Apple API key produced an invalid ECDSA signature"
    end
  end

  class HttpTransport
    def request(method, path, headers:, body: nil)
      uri = URI.join(API_BASE, path)
      raise Error, "refusing an App Store Connect link outside the API host" unless uri.host == API_HOST && uri.scheme == "https"

      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      request = request_class.new(uri.request_uri, headers)
      request.body = body if body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) do |http|
        http.request(request)
      end
      { status: response.code.to_i, body: response.body.to_s }
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => error
      raise Error, "App Store Connect request failed: #{error.class}"
    end
  end

  class Client
    def initialize(token_provider:, transport: HttpTransport.new, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleep_fn: ->(seconds) { sleep seconds }, timeout_seconds: DEFAULT_TIMEOUT_SECONDS, poll_seconds: DEFAULT_POLL_SECONDS)
      @token_provider = token_provider
      @transport = transport
      @clock = clock
      @sleep_fn = sleep_fn
      @timeout_seconds = timeout_seconds
      @poll_seconds = poll_seconds
    end

    def write(bundle_id:, version:, build_number:, notes:)
      validate_notes(notes)
      app = resolve_app(bundle_id)
      build = wait_for_build(app.fetch("id"), version, build_number)
      upsert_notes(build.fetch("id"), notes)
      puts "TestFlight What's New updated for iOS #{version} (#{build_number})."
    end

    private

    def validate_notes(notes)
      raise Error, "release notes are not valid UTF-8" unless notes.encoding == Encoding::UTF_8 && notes.valid_encoding?
      raise Error, "release notes are empty" if notes.strip.empty?
      raise Error, "release notes exceed #{MAX_NOTES_LENGTH} characters" if notes.length > MAX_NOTES_LENGTH
    end

    def resolve_app(bundle_id)
      apps = get_collection("/v1/apps?#{query('filter[bundleId]' => bundle_id, 'fields[apps]' => 'bundleId', 'limit' => '200')}")
      app = apps.find { |item| item.dig("attributes", "bundleId") == bundle_id }
      raise Error, "App Store Connect has no app with bundle ID #{bundle_id}" unless app

      app
    end

    def wait_for_build(app_id, version, build_number)
      started_at = @clock.call
      loop do
        build = matching_build(app_id, version, build_number)
        if build
          state = build.dig("attributes", "processingState")
          return build if state == "VALID"
          raise Error, "iOS build #{version} (#{build_number}) became #{state}" if %w[FAILED INVALID].include?(state)
        end

        elapsed = @clock.call - started_at
        raise Error, "timed out after #{@timeout_seconds}s waiting for iOS build #{version} (#{build_number}) to become VALID" if elapsed >= @timeout_seconds

        @sleep_fn.call([@poll_seconds, @timeout_seconds - elapsed].min)
      end
    end

    def matching_build(app_id, version, build_number)
      params = {
        'filter[app]' => app_id,
        'filter[version]' => build_number,
        'filter[preReleaseVersion.platform]' => 'IOS',
        'filter[preReleaseVersion.version]' => version,
        'fields[builds]' => 'version,processingState,preReleaseVersion',
        'fields[preReleaseVersions]' => 'version,platform',
        'include' => 'preReleaseVersion',
        'limit' => '200'
      }
      pages = get_collection_with_includes("/v1/builds?#{query(params)}")
      pages.each do |page|
        prereleases = page.fetch("included", []).select { |item| item["type"] == "preReleaseVersions" }.to_h { |item| [item["id"], item] }
        page.fetch("data", []).each do |build|
          prerelease_id = build.dig("relationships", "preReleaseVersion", "data", "id")
          prerelease = prereleases[prerelease_id]
          next unless build.dig("attributes", "version") == build_number
          next unless prerelease&.dig("attributes", "version") == version
          next unless prerelease&.dig("attributes", "platform") == "IOS"

          return build
        end
      end
      nil
    end

    def upsert_notes(build_id, notes)
      existing = english_localization(build_id)
      if existing
        response = if existing.dig("attributes", "whatsNew") == notes
                     existing
                   elsif existing.dig("attributes", "whatsNew").to_s.strip.empty?
                     request_json(:patch, "/v1/betaBuildLocalizations/#{escape(existing.fetch('id'))}", {
                       data: { type: "betaBuildLocalizations", id: existing.fetch("id"), attributes: { whatsNew: notes } }
                     }, [200]).fetch("data")
                   else
                     raise Error, "the existing TestFlight notes differ; published notes cannot be replaced"
                   end
      else
        response = request_json(:post, "/v1/betaBuildLocalizations", {
          data: {
            type: "betaBuildLocalizations",
            attributes: { locale: LOCALE, whatsNew: notes },
            relationships: { build: { data: { type: "builds", id: build_id } } }
          }
        }, [201]).fetch("data")
      end
      verify_notes(response, notes)
      verify_notes(english_localization(build_id), notes)
    end

    def english_localization(build_id)
      get_collection("/v1/builds/#{escape(build_id)}/betaBuildLocalizations?#{query('fields[betaBuildLocalizations]' => 'locale,whatsNew', 'limit' => '200')}")
        .find { |item| item.dig("attributes", "locale") == LOCALE }
    end

    def verify_notes(localization, notes)
      return if localization && localization.dig("attributes", "whatsNew") == notes

      raise Error, "App Store Connect did not save the TestFlight What's New text"
    end

    def get_collection(path)
      get_collection_with_includes(path).flat_map { |page| page.fetch("data", []) }
    end

    def get_collection_with_includes(path)
      pages = []
      seen = {}
      while path
        raise Error, "App Store Connect pagination exceeded #{MAX_PAGES} pages" if pages.length >= MAX_PAGES
        raise Error, "App Store Connect returned a repeated pagination link" if seen[path]

        seen[path] = true
        page = request_json(:get, path, nil, [200])
        pages << page
        path = page.dig("links", "next")
      end
      pages
    end

    def request_json(method, path, body, statuses)
      headers = {
        "Authorization" => "Bearer #{@token_provider.call}",
        "Accept" => "application/json"
      }
      encoded_body = body && JSON.generate(body)
      headers["Content-Type"] = "application/json" if encoded_body
      response = @transport.request(method, path, headers: headers, body: encoded_body)
      unless statuses.include?(response.fetch(:status))
        raise Error, "App Store Connect returned HTTP #{response.fetch(:status)} for #{method.to_s.upcase} #{safe_path(path)}"
      end
      JSON.parse(response.fetch(:body))
    rescue JSON::ParserError
      raise Error, "App Store Connect returned invalid JSON for #{method.to_s.upcase} #{safe_path(path)}"
    end

    def query(params)
      URI.encode_www_form(params)
    end

    def escape(value)
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    def safe_path(path)
      URI(path).path
    rescue URI::InvalidURIError
      path.split("?", 2).first
    end
  end

  def self.run(argv)
    unless argv.length == 4
      warn "Usage: #{$PROGRAM_NAME} BUNDLE_ID VERSION BUILD_NUMBER NOTES_FILE"
      return 2
    end
    bundle_id, version, build_number, notes_file = argv
    key_path = ENV.fetch("SHOWROOM_APPLE_KEY_PATH", "")
    key_id = ENV.fetch("SHOWROOM_APPLE_KEY_ID", "")
    issuer_id = ENV.fetch("SHOWROOM_APPLE_ISSUER_ID", "")
    raise Error, "Apple API credentials are incomplete; set SHOWROOM_APPLE_KEY_PATH, SHOWROOM_APPLE_KEY_ID, and SHOWROOM_APPLE_ISSUER_ID" if [key_path, key_id, issuer_id].any?(&:empty?)

    notes = File.binread(notes_file).force_encoding(Encoding::UTF_8)
    timeout = Integer(ENV.fetch("SNIP_SNAP_TESTFLIGHT_NOTES_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS.to_s), 10)
    poll = Integer(ENV.fetch("SNIP_SNAP_TESTFLIGHT_NOTES_POLL_SECONDS", DEFAULT_POLL_SECONDS.to_s), 10)
    raise Error, "TestFlight notes timeout and poll interval must be positive" unless timeout.positive? && poll.positive?

    Client.new(token_provider: TokenProvider.new(key_path: key_path, key_id: key_id, issuer_id: issuer_id), timeout_seconds: timeout, poll_seconds: poll)
          .write(bundle_id: bundle_id, version: version, build_number: build_number, notes: notes)
    0
  rescue Errno::ENOENT
    warn "TestFlight notes: release notes file is missing"
    1
  rescue ArgumentError
    warn "TestFlight notes: timeout and poll interval must be whole seconds"
    1
  rescue Error => error
    warn "TestFlight notes: #{error.message}"
    1
  end
end

exit TestFlightNotes.run(ARGV) if $PROGRAM_NAME == __FILE__
