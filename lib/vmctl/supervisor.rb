# frozen_string_literal: true
# lib/vmctl/supervisor.rb
require 'fileutils'
require_relative 'log'

module VMCtl
  # Runs and supervises one VM: loop bhyve, destroy the vmm device between runs,
  # relaunch only on a guest reboot. Plain Ruby fork/detach — no daemon(8).
  class Supervisor
    REBOOT_STATUS = 0

    def self.reboot?(status)
      status == REBOOT_STATUS
    end

    # runner: callable returning the bhyve exit status Integer.
    #         Defaults to actually spawning bhyve (production path).
    def initialize(vm, executor:, runner: nil)
      @vm = vm
      @exec = executor
      @runner = runner || method(:spawn_bhyve)
      @poweroff_requested = false
    end

    # The core loop. Testable with an injected runner + FakeExecutor.
    def supervise
      loop do
        break if @poweroff_requested # a stop requested between runs must not relaunch
        status = @runner.call
        @exec.run('bhyvectl', '--destroy', "--vm=#{@vm.name}")
        break if @poweroff_requested
        break unless self.class.reboot?(status)
      end
    end

    # Request a graceful stop: the loop will not relaunch after the current run.
    # Called from the TERM handler (and from tests to simulate a stop signal).
    def request_poweroff
      @poweroff_requested = true
    end

    # Fork a detached supervisor, write the pidfile, redirect output.
    # Returns the supervisor pid.
    def start
      ensure_dirs
      pid = fork do
        Process.setsid
        redirect_output
        File.write(@vm.pidfile, Process.pid.to_s)
        at_exit { remove_pidfile }
        install_signal_handlers
        Thread.current[:vmctl_vm] = @vm.name
        supervise
      end
      Process.detach(pid)
      pid
    end

    private

    # Production runner: spawn bhyve, remember its pid (for signal forwarding),
    # wait, return its exit status.
    def spawn_bhyve
      VMCtl.logger.info("launch: #{@vm.bhyve_command}")
      @bhyve_pid = Process.spawn(*@vm.bhyve_argv)
      _pid, status = Process.wait2(@bhyve_pid)
      @bhyve_pid = nil
      status.exitstatus || 1
    end

    # On TERM: stop after the current run, and force-poweroff the live guest.
    def install_signal_handlers
      Signal.trap('TERM') do
        request_poweroff
        @exec.run('bhyvectl', '--force-poweroff', "--vm=#{@vm.name}") if @bhyve_pid
      end
    end

    def ensure_dirs
      FileUtils.mkdir_p(@vm.defaults.run_dir)
      FileUtils.mkdir_p(@vm.defaults.log_dir)
    end

    def redirect_output
      log = File.open(@vm.logfile, 'a')
      log.sync = true
      $stdout.reopen(log)
      $stderr.reopen(log)
      $stdin.reopen(File::NULL)
    end

    def remove_pidfile
      File.delete(@vm.pidfile) if File.exist?(@vm.pidfile)
    end
  end
end
