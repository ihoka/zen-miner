# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/directory_manager'

class DirectoryManagerTest < Minitest::Test
  def setup
    @logger = mock_logger
    @manager = Installer::DirectoryManager.new(logger: @logger)
  end

  def test_execute_success_when_all_directories_and_files_created
    @manager.stub :file_exists?, false do
      Open3.stub :capture3, lambda { |*args|
        ["", "", mock_status(true)]
      } do
        result = @manager.execute

        assert result.success?
        assert_equal "All directories and files created", result.message

        # Verify all directories were created
        messages = @logger.messages.map { |_, msg| msg }
        assert messages.any? { |msg| msg.include?("/var/log/xmrig") }
        assert messages.any? { |msg| msg.include?("/etc/xmrig") }
        assert messages.any? { |msg| msg.include?("/var/lib/xmrig-orchestrator/gems") }
        assert messages.any? { |msg| msg.include?("/mnt/rails-storage") }
        assert messages.any? { |msg| msg.include?("/var/log/xmrig/orchestrator.log") }
      end
    end
  end

  def test_execute_fails_when_mkdir_fails
    @manager.stub :file_exists?, false do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('mkdir')
          ["", "Permission denied", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to create directory"
        assert_includes result.message, "Permission denied"
      end
    end
  end

  def test_execute_fails_when_chown_fails
    @manager.stub :file_exists?, lambda { |path| !path.include?('mkdir') } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('chown')
          ["", "Operation not permitted", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to set ownership"
      end
    end
  end

  def test_execute_fails_when_chmod_fails
    @manager.stub :file_exists?, lambda { |path| !path.include?('mkdir') } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('chmod')
          ["", "Operation not permitted", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to set permissions"
      end
    end
  end

  def test_execute_skips_existing_directories
    # Simulate first directory exists, others don't
    first_dir = Installer::DirectoryManager::DIRECTORIES.first[:path]

    @manager.stub :file_exists?, lambda { |path| path == first_dir } do
      Open3.stub :capture3, lambda { |*args|
        ["", "", mock_status(true)]
      } do
        result = @manager.execute

        assert result.success?

        # Verify mkdir was NOT called for existing directory
        messages = @logger.messages.map { |_, msg| msg }
        refute messages.any? { |msg| msg.include?("Created directory #{first_dir}") },
               "Should not show 'Created' message for existing directory"
      end
    end
  end

  def test_execute_creates_file_when_missing
    @manager.stub :file_exists?, false do
      commands_run = []

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        commands_run << cmd
        ["", "", mock_status(true)]
      } do
        result = @manager.execute

        assert result.success?

        # Verify touch command was run for file creation
        assert commands_run.any? { |cmd| cmd.include?('touch') && cmd.include?('orchestrator.log') },
               "Expected touch command to create log file"
      end
    end
  end

  def test_execute_fails_when_touch_fails
    @manager.stub :file_exists?, lambda { |path|
      # Directories exist, file doesn't
      !path.include?('orchestrator.log')
    } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('touch')
          ["", "Permission denied", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to create file"
      end
    end
  end

  def test_directories_constant_includes_all_required_paths
    paths = Installer::DirectoryManager::DIRECTORIES.map { |d| d[:path] }

    assert_includes paths, '/var/log/xmrig'
    assert_includes paths, '/etc/xmrig'
    assert_includes paths, '/var/lib/xmrig-orchestrator/gems'
    assert_includes paths, '/mnt/rails-storage'
  end

  def test_files_constant_includes_log_file
    paths = Installer::DirectoryManager::FILES.map { |f| f[:path] }

    assert_includes paths, '/var/log/xmrig/orchestrator.log'
  end

  def test_rails_storage_has_correct_permissions
    rails_storage = Installer::DirectoryManager::DIRECTORIES.find { |d| d[:path] == '/mnt/rails-storage' }

    assert_equal '1000', rails_storage[:owner]
    assert_equal 'deploy', rails_storage[:group]
    assert_equal '0775', rails_storage[:mode]
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
