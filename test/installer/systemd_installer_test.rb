# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/systemd_installer'

class SystemdInstallerTest < Minitest::Test
  def setup
    @logger = mock_logger
  end

  def test_execute_success_when_services_installed
    with_temp_dir do |tmpdir|
      # Create fake service files
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]\nDescription=XMRig")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]\nDescription=Orchestrator")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        # After restart, is-active check should return true (service is running)
        if cmd.include?('is-active')
          ["", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        Kernel.stub :sleep, nil do
          result = @installer.execute

          assert result.success?
          assert_equal "Systemd services installed and enabled", result.message

          messages = @logger.messages.map { |_, msg| msg }
          assert messages.any? { |msg| msg.include?("xmrig.service") }
          assert messages.any? { |msg| msg.include?("xmrig-orchestrator.service") }
          assert messages.any? { |msg| msg.include?("Systemd daemon reloaded") }
        end
      end
    end
  end

  def test_execute_restarts_orchestrator_if_running
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      call_count = 0
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('is-active')
          call_count += 1
          # First is-active check: running
          # Second is-active check (after restart): also running
          ["", "", mock_status(true)]
        elsif cmd.include?('restart')
          ["", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        # Stub sleep to speed up test
        Kernel.stub :sleep, nil do
          result = @installer.execute

          assert result.success?

          messages = @logger.messages.map { |_, msg| msg }
          assert messages.any? { |msg| msg.include?("Orchestrator restarted") }
          assert messages.any? { |msg| msg.include?("Services verified") }
        end
      end
    end
  end

  def test_execute_fails_if_orchestrator_restart_fails
    # Updated to match new behavior: installer fails if orchestrator restart fails
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('restart xmrig-orchestrator')
          ["", "Failed to restart orchestrator", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        # Should fail if orchestrator restart fails
        refute result.success?
        assert_includes result.message, "Failed to restart orchestrator"
      end
    end
  end

  def test_execute_fails_when_service_file_not_found
    @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: '/nonexistent')

    File.stub :exist?, false do
      result = @installer.execute

      assert result.failure?
      assert_includes result.message, "Could not find service file"
    end
  end

  def test_execute_fails_when_cp_fails
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('cp')
          ["", "Permission denied", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        assert result.failure?
        assert_includes result.message, "Failed to copy service file"
      end
    end
  end

  def test_execute_fails_when_daemon_reload_fails
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('daemon-reload')
          ["", "Failed to reload", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        assert result.failure?
        assert_includes result.message, "Failed to reload systemd"
      end
    end
  end

  def test_execute_fails_when_enable_fails
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('enable')
          ["", "Service not found", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        assert result.failure?
        assert_includes result.message, "Failed to enable service"
      end
    end
  end

  def test_always_restarts_services
    # Purpose: Verify that services are always restarted when installer runs
    # This test validates the "always execute" behavior - services restart every time
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      restart_count = 0

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        # Count service restart operations
        restart_count += 1 if cmd.include?('systemctl restart')
        ["", "", mock_status(true)]
      } do
        Kernel.stub :sleep, nil do
          # First execution
          result1 = @installer.execute
          assert result1.success?

          # Second execution - should restart again (no idempotency)
          result2 = @installer.execute
          assert result2.success?

          # Verify both executions restarted services
          # Each execution restarts orchestrator (always) + xmrig (may fail)
          # Minimum 2 restart attempts per execution = 4 total
          assert restart_count >= 4, "Services should be restarted on every execution (got #{restart_count} restarts)"
        end
      end
    end
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
