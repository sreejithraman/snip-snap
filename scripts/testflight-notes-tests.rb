#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "testflight-notes"

module TestFlightNotesTests
  def self.assert(condition, message)
    raise message unless condition
  end

  def self.json(data)
    JSON.generate(data)
  end

  def self.response(status, data)
    { status: status, body: json(data) }
  end

  def self.app_page(bundle_id, next_link: nil)
    links = next_link ? { "next" => next_link } : {}
    { "data" => [{ "type" => "apps", "id" => "app-id", "attributes" => { "bundleId" => bundle_id } }], "links" => links }
  end

  def self.build(id:, build:, state:, release:, platform: "IOS")
    {
      "data" => [{
        "type" => "builds", "id" => id,
        "attributes" => { "version" => build, "processingState" => state },
        "relationships" => { "preReleaseVersion" => { "data" => { "type" => "preReleaseVersions", "id" => "prerelease-#{id}" } } }
      }],
      "included" => [{ "type" => "preReleaseVersions", "id" => "prerelease-#{id}", "attributes" => { "version" => release, "platform" => platform } }]
    }
  end

  class FakeTransport
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def request(method, path, headers:, body: nil)
      @calls << { method: method, path: path, headers: headers, body: body }
      @handler.call(method, path, headers, body, @calls.length)
    end
  end

  class CountingToken
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def call
      @calls += 1
      "test-token-#{@calls}"
    end
  end

  def self.client(transport, token: CountingToken.new, clock: -> { 0 }, sleep_fn: ->(_seconds) {}, timeout: 30, poll: 5)
    [TestFlightNotes::Client.new(token_provider: token, transport: transport, clock: clock, sleep_fn: sleep_fn, timeout_seconds: timeout, poll_seconds: poll), token]
  end

  def self.test_retries_and_fill_blank_notes_with_pagination
    bundle_id = "com.example.snipsnap"
    build_requests = 0
    localization_reads = 0
    slept = []
    transport = FakeTransport.new do |method, path, _headers, body, _count|
      case
      when method == :get && path == "/v1/apps?page=2"
        response(200, app_page(bundle_id))
      when method == :get && path.start_with?("/v1/apps?")
        response(200, { "data" => [], "links" => { "next" => "/v1/apps?page=2" } })
      when method == :get && path.start_with?("/v1/builds?")
        build_requests += 1
        if build_requests == 1
          response(200, {
            "data" => build(id: "wrong-build", build: "8", state: "VALID", release: "1.4.0").fetch("data") +
                      build(id: "wrong-release", build: "7", state: "VALID", release: "9.9.9").fetch("data") +
                      build(id: "mac-build", build: "7", state: "VALID", release: "1.4.0", platform: "MAC_OS").fetch("data") +
                      build(id: "pending", build: "7", state: "PROCESSING", release: "1.4.0").fetch("data"),
            "included" => build(id: "wrong-build", build: "8", state: "VALID", release: "1.4.0").fetch("included") +
                          build(id: "wrong-release", build: "7", state: "VALID", release: "9.9.9").fetch("included") +
                          build(id: "mac-build", build: "7", state: "VALID", release: "1.4.0", platform: "MAC_OS").fetch("included") +
                          build(id: "pending", build: "7", state: "PROCESSING", release: "1.4.0").fetch("included")
          })
        else
          response(200, build(id: "pending", build: "7", state: "VALID", release: "1.4.0"))
        end
      when method == :get && path == "/v1/builds/pending/betaBuildLocalizations?page=2"
        response(200, { "data" => [{ "type" => "betaBuildLocalizations", "id" => "english", "attributes" => { "locale" => "en-US", "whatsNew" => "" } }] })
      when method == :get && path.start_with?("/v1/builds/pending/betaBuildLocalizations?")
        localization_reads += 1
        if localization_reads == 1
          response(200, {
            "data" => [{ "type" => "betaBuildLocalizations", "id" => "french", "attributes" => { "locale" => "fr-FR", "whatsNew" => "French" } }],
            "links" => { "next" => "/v1/builds/pending/betaBuildLocalizations?page=2" }
          })
        else
          response(200, { "data" => [{ "type" => "betaBuildLocalizations", "id" => "english", "attributes" => { "locale" => "en-US", "whatsNew" => "New notes" } }] })
        end
      when method == :patch && path == "/v1/betaBuildLocalizations/english"
        payload = JSON.parse(body)
        assert(payload.dig("data", "attributes", "whatsNew") == "New notes", "the update payload did not contain the notes")
        response(200, { "data" => { "type" => "betaBuildLocalizations", "id" => "english", "attributes" => { "locale" => "en-US", "whatsNew" => "New notes" } } })
      else
        raise "unexpected request #{method} #{path}"
      end
    end
    client, token = client(transport, sleep_fn: ->(seconds) { slept << seconds })
    client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "New notes")
    assert(build_requests == 2, "a processing build was not retried")
    assert(slept == [5], "the retry did not use the poll interval")
    assert(transport.calls.any? { |call| call[:method] == :patch }, "an existing localization was not updated")
    assert(token.calls == transport.calls.length, "the JWT was not refreshed for each request")
  end

  def self.test_create_and_idempotent_reread
    bundle_id = "com.example.snipsnap"
    localization_reads = 0
    transport = FakeTransport.new do |method, path, _headers, body, _count|
      case
      when method == :get && path.start_with?("/v1/apps?")
        response(200, app_page(bundle_id))
      when method == :get && path.start_with?("/v1/builds?")
        response(200, build(id: "build-7", build: "7", state: "VALID", release: "1.4.0"))
      when method == :get && path.start_with?("/v1/builds/build-7/betaBuildLocalizations?")
        localization_reads += 1
        response(200, { "data" => localization_reads == 1 ? [] : [{ "type" => "betaBuildLocalizations", "id" => "new", "attributes" => { "locale" => "en-US", "whatsNew" => "New notes" } }] })
      when method == :post && path == "/v1/betaBuildLocalizations"
        payload = JSON.parse(body)
        assert(payload.dig("data", "relationships", "build", "data", "id") == "build-7", "the new localization targeted the wrong build")
        response(201, { "data" => { "type" => "betaBuildLocalizations", "id" => "new", "attributes" => { "locale" => "en-US", "whatsNew" => "New notes" } } })
      else
        raise "unexpected request #{method} #{path}"
      end
    end
    client, = client(transport)
    client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "New notes")
    assert(transport.calls.count { |call| call[:method] == :post } == 1, "a missing localization was not created")
    assert(localization_reads == 2, "the created localization was not read back")
  end

  def self.test_failure_and_timeout
    bundle_id = "com.example.snipsnap"
    invalid_transport = FakeTransport.new do |method, path, _headers, _body, _count|
      method == :get && path.start_with?("/v1/apps?") ? response(200, app_page(bundle_id)) : response(200, build(id: "bad", build: "7", state: "INVALID", release: "1.4.0"))
    end
    invalid_client, = client(invalid_transport)
    begin
      invalid_client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "Notes")
      raise "an invalid build was accepted"
    rescue TestFlightNotes::Error => error
      assert(error.message.include?("became INVALID"), "invalid-build error was unclear")
    end

    time = 0
    timeout_transport = FakeTransport.new do |method, path, _headers, _body, _count|
      method == :get && path.start_with?("/v1/apps?") ? response(200, app_page(bundle_id)) : response(200, build(id: "wrong", build: "8", state: "VALID", release: "1.4.0"))
    end
    timeout_client, = client(timeout_transport, clock: -> { time }, sleep_fn: ->(seconds) { time += seconds }, timeout: 10, poll: 5)
    begin
      timeout_client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "Notes")
      raise "a missing exact build was accepted"
    rescue TestFlightNotes::Error => error
      assert(error.message.include?("timed out after 10s"), "timeout error was unclear")
    end
  end

  def self.test_existing_matching_notes_need_no_update
    bundle_id = "com.example.snipsnap"
    transport = FakeTransport.new do |method, path, _headers, _body, _count|
      case
      when method == :get && path.start_with?("/v1/apps?")
        response(200, app_page(bundle_id))
      when method == :get && path.start_with?("/v1/builds?")
        response(200, build(id: "build-7", build: "7", state: "VALID", release: "1.4.0"))
      when method == :get && path.start_with?("/v1/builds/build-7/betaBuildLocalizations?")
        response(200, { "data" => [{ "type" => "betaBuildLocalizations", "id" => "existing", "attributes" => { "locale" => "en-US", "whatsNew" => "Same notes" } }] })
      else
        raise "unexpected request #{method} #{path}"
      end
    end
    client, = client(transport)
    client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "Same notes")
    assert(transport.calls.none? { |call| %i[post patch].include?(call[:method]) }, "matching notes were rewritten")
    begin
      client.write(bundle_id: bundle_id, version: "1.4.0", build_number: "7", notes: "Different notes")
      raise "published notes were replaced"
    rescue TestFlightNotes::Error => error
      assert(error.message.include?("published notes cannot be replaced"), "mismatched-notes error was unclear")
    end
    assert(transport.calls.none? { |call| %i[post patch].include?(call[:method]) }, "different published notes caused a write")
  end

  def self.test_empty_notes_fail_before_a_request
    transport = FakeTransport.new { raise "release notes validation made a request" }
    client, = client(transport)
    begin
      client.write(bundle_id: "com.example.snipsnap", version: "1.4.0", build_number: "7", notes: " \n\t")
      raise "blank release notes were accepted"
    rescue TestFlightNotes::Error => error
      assert(error.message == "release notes are empty", "blank-notes error was unclear")
    end
    assert(transport.calls.empty?, "blank release notes reached App Store Connect")
  end

  def self.test_der_to_jose
    key = OpenSSL::PKey::EC.generate("prime256v1")
    message = "App Store Connect"
    der = key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(message))
    jose = TestFlightNotes::TokenProvider.der_to_jose(der)
    assert(jose.bytesize == 64, "the JOSE ECDSA signature was not 64 bytes")

    Tempfile.create(["testflight-notes", ".p8"]) do |file|
      file.binmode
      file.write(key.to_pem)
      file.flush
      token = TestFlightNotes::TokenProvider.new(key_path: file.path, key_id: "key-id", issuer_id: "issuer-id", now: -> { 100 }).call
      header, payload, signature = token.split(".")
      assert(JSON.parse(Base64.urlsafe_decode64(header))["alg"] == "ES256", "the JWT did not use ES256")
      assert(JSON.parse(Base64.urlsafe_decode64(payload))["aud"] == "appstoreconnect-v1", "the JWT had the wrong audience")
      assert(Base64.urlsafe_decode64(signature).bytesize == 64, "the JWT did not use a JOSE ECDSA signature")
    end
  end

  def self.run
    test_retries_and_fill_blank_notes_with_pagination
    test_create_and_idempotent_reread
    test_failure_and_timeout
    test_existing_matching_notes_need_no_update
    test_empty_notes_fail_before_a_request
    test_der_to_jose
    puts "TestFlight notes checks passed."
  end
end

TestFlightNotesTests.run
