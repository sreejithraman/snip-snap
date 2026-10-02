#!/usr/bin/env ruby
# Read-only comparison of the live codec schema with a cktool schema export.
require 'strscan'
require 'json'

module CloudKitSchema
  class InvalidSchema < StandardError; end
  TYPES = %w[INT64 DOUBLE STRING BYTES TIMESTAMP REFERENCE LOCATION ASSET].freeze
  INDEXES = %w[QUERYABLE SORTABLE SEARCHABLE].freeze

  class Parser
    def initialize(text)
      @scanner = StringScanner.new(text)
      @token = next_token
    end

    def next_token
      loop do
        @scanner.skip(/\s+/)
        next if @scanner.scan(%r{//[^\n]*(?:\n|\z)})
        if @scanner.scan(%r{/\*})
          raise InvalidSchema, 'unclosed comment' unless @scanner.scan_until(%r{\*/})
          next
        end
        break
      end
      return nil if @scanner.eos?
      value = @scanner.scan(/"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_.]*|[(),;<>]/)
      raise InvalidSchema, 'unrecognized schema syntax' unless value
      value
    end

    def take
      value = @token
      @token = next_token
      value
    end

    def expect(value)
      raise InvalidSchema, "expected #{value}, found #{@token.inspect}" unless @token == value
      take
    end

    def identifier
      value = take
      raise InvalidSchema, 'expected identifier' unless value && value.match?(/\A(?:".*"|[A-Za-z_][A-Za-z0-9_.]*)\z/)
      value.start_with?('"') ? JSON.parse(value) : value
    end

    def field_type
      if @token == 'LIST'
        take
        expect('<')
        element = scalar_type
        expect('>')
        "LIST<#{element}>"
      else
        scalar_type
      end
    end

    def scalar_type
      value = take
      raise InvalidSchema, "unsupported field type #{value.inspect}" unless TYPES.include?(value)
      value
    end

    def parse
      expect('DEFINE')
      expect('SCHEMA')
      records = {}
      while @token
        expect('RECORD')
        expect('TYPE')
        name = identifier
        raise InvalidSchema, "duplicate record type #{name}" if records.key?(name)
        fields = records[name] = {}
        expect('(')
        until @token == ')'
          if @token == 'GRANT'
            take
            permission = take
            raise InvalidSchema, 'unsupported permission' unless %w[READ WRITE CREATE].include?(permission)
            expect('TO')
            identifier
          else
            field = identifier
            raise InvalidSchema, "duplicate field #{name}.#{field}" if fields.key?(field)
            encrypted = @token == 'ENCRYPTED'
            take if encrypted
            type = field_type
            fields[field] = [type, encrypted]
            take while INDEXES.include?(@token)
          end
          break if @token == ')'
          expect(',')
        end
        expect(')')
        expect(';')
      end
      raise InvalidSchema, 'schema contains no record types' if records.empty?
      records
    end
  end

  def self.describe(contract)
    type, encrypted = contract
    "#{encrypted ? 'ENCRYPTED ' : ''}#{type}"
  end

  def self.compare(live, deployed)
    issues = []
    live.sort.each do |record, fields|
      unless deployed.key?(record)
        issues << "missing record type #{record}"
      end
      fields.sort.each do |field, contract|
        actual = deployed.fetch(record, {})[field]
        if actual.nil?
          issues << "missing field #{record}.#{field} (expected #{describe(contract)})"
        elsif actual != contract
          issues << "incompatible field #{record}.#{field}: expected #{describe(contract)}, Production has #{describe(actual)}"
        end
      end
    end
    issues
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise ArgumentError, 'Usage: cloudkit-schema.rb LIVE.ckdb EXPORTED.ckdb (offline comparison only)' unless ARGV.length == 2
    live, deployed = ARGV.map { |file| CloudKitSchema::Parser.new(File.read(file)).parse }
    issues = CloudKitSchema.compare(live, deployed)
    if issues.any?
      issues.each { |issue| warn "CloudKit preflight: #{issue}" }
      warn 'CloudKit preflight: blocked; review an additive schema rollout, retain retired fields, then rerun. No schema changes were made.'
      exit 1
    end
    puts "CloudKit schema compatible: #{live.length} live record types; extra deployed fields and record types retained."
  rescue CloudKitSchema::InvalidSchema, ArgumentError, SystemCallError, JSON::ParserError => error
    warn "CloudKit preflight: #{error.message}"
    exit 2
  end
end
