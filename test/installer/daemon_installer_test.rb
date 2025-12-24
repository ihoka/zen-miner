# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/daemon_installer'

class DaemonInstallerTest < Minitest::Test
  def setup
    @logger = mock_logger
  end

  def mock_xmrig_commands(xmrig_path: "/usr/bin/xmrig")
    lambda do |*args|
      cmd = args.join(' ')
      if cmd.include?('which xmrig')
        [xmrig_path + "\n", "", mock_status(true)]
      elsif cmd.include?('--version') || args.include?('--version')
        ["XMRig 6.18.0\n", "", mock_status(true)]
      elsif cmd.include?('readlink') || args.include?('readlink')
        [xmrig_path + "\n", "", mock_status(true)]
      else
        ["", "", mock_status(true)]
      end
    end
  end

  def test_execute_success_when_daemon_installed
    with_temp_dir do |tmpdir|
      # Create a fake daemon source file
      source_daemon = File.join(tmpdir, 'xmrig-orchestrator')
      File.write(source_daemon, "#!/usr/bin/env ruby\n# Fake daemon")

      @installer = Installer::DaemonInstaller.new(logger: @logger, script_dir: tmpdir)

      @installer.stub :file_exists?, false do
        @installer.stub :file_executable?, false do
          Open3.stub :capture3, mock_xmrig_commands do
            result = @installer.execute

            assert result.success?
            assert_equal "Orchestrator daemon installed", result.message

            # Verify all steps logged
            messages = @logger.messages.map { |_, msg| msg }
            assert messages.any? { |msg| msg.include?("XMRig found at") }
            assert messages.any? { |msg| msg.include?("XMRig validated") || msg.include?("standard location") }
            assert messages.any? { |msg| msg.include?("Orchestrator installed") }
            assert messages.any? { |msg| msg.include?("Daemon made executable") }
          end
        end
      end
    end
  end

  def test_execute_fails_when_source_daemon_not_found
    @installer = Installer::DaemonInstaller.new(logger: @logger, script_dir: '/nonexistent')

    # Mock File.exist? to return false for all daemon source paths
    File.stub :exist?, false do
      result = @installer.execute

      assert result.failure?
      assert_includes result.message, "Could not find xmrig-orchestrator source file"
    end
  end

  def test_execute_fails_when_xmrig_not_in_path
    with_temp_dir do |tmpdir|
      source_daemon = File.join(tmpdir, 'xmrig-orchestrator')
      File.write(source_daemon, "#!/usr/bin/env ruby")

      @installer = Installer::DaemonInstaller.new(logger: @logger, script_dir: tmpdir)

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('which xmrig')
          ["", "xmrig not found", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @installer.execute

        assert result.failure?
        assert_includes result.message, "XMRig binary not found in PATH"
      end
    end
  end

  def test_execute_fails_when_cp_fails
    with_temp_dir do |tmpdir|
      source_daemon = File.join(tmpdir, 'xmrig-orchestrator')
      File.write(source_daemon, "#!/usr/bin/env ruby")

      @installer = Installer::DaemonInstaller.new(logger: @logger, script_dir: tmpdir)

      @installer.stub :file_exists?, false do
        @installer.stub :file_executable?, false do
          Open3.stub :capture3, lambda { |*args|
            cmd = args.join(' ')
            if cmd.include?('which xmrig')
              ["/usr/bin/xmrig\n", "", mock_status(true)]
            elsif cmd.include?('--version') || args.include?('--version')
              ["XMRig 6.18.0\n", "", mock_status(true)]
            elsif cmd.include?('readlink') || args.include?('readlink')
              ["/usr/bin/xmrig\n", "", mock_status(true)]
            elsif cmd.include?('cp') || args.include?('cp')
              ["", "Permission denied", mock_status(false)]
            else
              ["", "", mock_status(true)]
            end
          } do
            result = @installer.execute

            assert result.failure?
            assert_includes result.message, "Failed to install daemon"
          end
        end
      end
    end
  end

  def test_execute_fails_when_chmod_fails
    with_temp_dir do |tmpdir|
      source_daemon = File.join(tmpdir, 'xmrig-orchestrator')
      File.write(source_daemon, "#!/usr/bin/env ruby")

      @installer = Installer::DaemonInstaller.new(logger: @logger, script_dir: tmpdir)

      @installer.stub :file_exists?, false do
        @installer.stub :file_executable?, false do
          Open3.stub :capture3, lambda { |*args|
            cmd = args.join(' ')
            if cmd.include?('which xmrig')
              ["/usr/bin/xmrig\n", "", mock_status(true)]
            elsif cmd.include?('--version') || args.include?('--version')
              ["XMRig 6.18.0\n", "", mock_status(true)]
            elsif cmd.include?('readlink') || args.include?('readlink')
              ["/usr/bin/xmrig\n", "", mock_status(true)]
            elsif cmd.include?('chmod') || args.include?('chmod')
              ["", "Operation not permitted", mock_status(false)]
            else
              ["", "", mock_status(true)]
            end
          } do
            result = @installer.execute

            assert result.failure?
            assert_includes result.message, "Failed to make daemon executable"
          end
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
