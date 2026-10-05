# test/test_rc_script.rb
require_relative 'test_helper'
require 'tmpdir'

# rc/vmctl runs at boot with rc's PATH (/sbin:/bin:/usr/sbin:/usr/bin), but
# bin/vmctl is `#!/usr/bin/env ruby` and ruby lives in /usr/local/bin. On mir
# 2026-10-05 that left buildbox down after a power loss: "env: ruby: No such
# file or directory" on the console, nothing in /var/log/messages.
class TestRcScript < Minitest::Test
  RC = File.expand_path('../rc/vmctl', __dir__)
  BOOT_PATH = '/sbin:/bin:/usr/sbin:/usr/bin'

  def run_rc(cmd)
    Dir.mktmpdir do |d|
      File.write("#{d}/rc.subr", <<~SH)
        load_rc_config() { :; }
        run_rc_command() { case "$1" in start) $start_cmd ;; stop) $stop_cmd ;; esac; }
      SH
      File.write("#{d}/vmctl", "#!/bin/sh\necho \"$PATH\" > #{d}/path\necho \"$*\" > #{d}/argv\n")
      File.chmod(0o755, "#{d}/vmctl")
      File.write("#{d}/rc", File.read(RC).sub('. /etc/rc.subr', ". #{d}/rc.subr"))
      ok = system({ 'PATH' => BOOT_PATH, 'vmctl_bin' => "#{d}/vmctl" }, '/bin/sh', "#{d}/rc", cmd,
                  unsetenv_others: true)
      assert ok, "rc #{cmd} failed"
      [File.read("#{d}/path").strip.split(':'), File.read("#{d}/argv").strip]
    end
  end

  def test_start_gives_vmctl_a_path_with_usr_local_bin
    path, argv = run_rc('start')
    assert_includes path, '/usr/local/bin'
    assert_equal 'start --all', argv
  end

  def test_stop_does_too_so_shutdown_stops_vms_cleanly
    path, argv = run_rc('stop')
    assert_includes path, '/usr/local/bin'
    assert_equal 'stop --all', argv
  end

  def test_base_paths_are_kept
    path, = run_rc('start')
    BOOT_PATH.split(':').each { |p| assert_includes path, p }
  end
end
