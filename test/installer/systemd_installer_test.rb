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
        if cmd.include?('is-active')
          ["", "", mock_status(false)]  # Not running
        else
          ["", "", mock_status(true)]
        end
      } do
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
          assert messages.any? { |msg| msg.include?("Restarting orchestrator") }
          assert messages.any? { |msg| msg.include?("Orchestrator restarted successfully") }
        end
      end
    end
  end

  def test_execute_continues_if_restart_fails
    with_temp_dir do |tmpdir|
      File.write(File.join(tmpdir, 'xmrig.service'), "[Unit]")
      File.write(File.join(tmpdir, 'xmrig-orchestrator.service'), "[Unit]")

      @installer = Installer::SystemdInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('restart')
          ["", "Failed to restart", mock_status(false)]
        elsif cmd.include?('is-active')
          ["", "", mock_status(true)]  # Running initially
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        # Should still succeed even if restart fails
        assert result.success?

        # But should log a warning
        messages = @logger.messages
        warnings = messages.select { |level, _| level == :warn }
        assert warnings.any?, "Expected a warning message about restart failure"
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

  def test_completed_returns_true_when_service_files_exist
    @installer = Installer::SystemdInstaller.new(logger: @logger)

    @installer.stub :file_exists?, true do
      assert @installer.completed?, "Should be completed when all service files exist"
    end
  end

  def test_completed_returns_false_when_service_files_missing
    @installer = Installer::SystemdInstaller.new(logger: @logger)

    @installer.stub :file_exists?, false do
      refute @installer.completed?, "Should not be completed when service files are missing"
    end
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
