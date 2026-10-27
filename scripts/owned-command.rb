#!/usr/bin/ruby
require 'fileutils'

# A separate group contains only this invocation and children that inherit it.
class OwnedCommand
  def initialize(timeout:, marker:, command:)
    @timeout = timeout
    @marker = marker
    @command = command
    @cancelled = nil
    %w[INT TERM].each { |signal| Signal.trap(signal) { @cancelled = signal } }
  end

  def run
    started = monotonic_time
    @pid = Process.spawn(*@command, pgroup: true)
    File.write(@marker, "#{@pid}\n")
    result = nil
    loop do
      waited = Process.waitpid2(@pid, Process::WNOHANG)
      if waited
        @reaped = true
        result = @cancelled ? cancellation_status : (waited.last.exitstatus || 128 + waited.last.termsig)
        break
      end
      if @cancelled
        result = cancellation_status
        break
      end
      if @timeout.positive? && monotonic_time - started >= @timeout
        warn "Owned command timed out after #{@timeout}s; stopping its command group."
        result = 124
        break
      end
      sleep 0.05
    end
    result
  ensure
    if @pid
      stop_group
      Process.waitpid(@pid) unless @reaped
      FileUtils.rm_f(@marker)
    end
  end

  private

  def cancellation_status
    @cancelled == 'INT' ? 130 : 143
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def group_running?
    if !@reaped && Process.waitpid(@pid, Process::WNOHANG)
      @reaped = true
    end
    Process.kill(0, -@pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def signal_group(signal)
    Process.kill(signal, -@pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def stop_group
    return unless group_running?

    signal_group('TERM')
    deadline = monotonic_time + 2
    sleep 0.05 while group_running? && monotonic_time < deadline
    signal_group('KILL') if group_running?
    unless @reaped
      Process.waitpid(@pid)
      @reaped = true
    end
    # Keep the slot marker while any owned process can still write build output.
    sleep 0.05 while group_running?
  end
end

begin
  timeout = Float(ARGV.shift)
  marker = ARGV.shift
  raise ArgumentError unless timeout.finite? && timeout >= 0 && marker && !ARGV.empty?
  exit OwnedCommand.new(timeout: timeout, marker: marker, command: ARGV).run
rescue ArgumentError, TypeError
  warn 'Usage: owned-command.rb TIMEOUT_SECONDS MARKER COMMAND [ARGUMENT...] (0 disables timeout)'
  exit 2
end
