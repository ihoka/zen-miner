# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/sudo_configurator'

class SudoConfiguratorTest < Minitest::Test
  def setup
    @logger = mock_logger
    @configurator = Installer::SudoConfigurator.new(logger: @logger)
  end

  def test_execute_success_when_sudoers_configured
    Open3.stub :capture3, lambda { |*args|
      ["", "", mock_status(true)]
    } do
      result = @configurator.execute

      assert result.success?
      assert_equal "Sudo permissions configured", result.message

      # Verify all steps were logged
      messages = @logger.messages.map { |_, msg| msg }
      assert messages.any? { |msg| msg.include?("Sudoers file written") }
      assert messages.any? { |msg| msg.include?("Sudo permissions configured") }
      assert messages.any? { |msg| msg.include?("Sudoers syntax validated") }
    end
  end

  def test_execute_fails_when_write_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(' ')
      if cmd.include?('cat >')
        ["", "Permission denied", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Failed to write sudoers file"
      assert_includes result.message, "Permission denied"
    end
  end

  def test_execute_fails_when_chmod_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(' ')
      if cmd.include?('chmod')
        ["", "Operation not permitted", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Failed to set permissions"
    end
  end

  def test_execute_fails_when_mv_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(' ')
      if cmd.include?('mv')
        ["", "Cannot move file", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Failed to move sudoers file"
    end
  end

  def test_execute_fails_when_visudo_validation_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(' ')
      if cmd.include?('visudo')
        ["", "syntax error on line 2", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Sudoers syntax validation failed"
      assert_includes result.message, "syntax error"
    end
  end

  def test_execute_removes_file_on_validation_failure
    commands_run = []

    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(' ')
      commands_run << cmd

      if cmd.include?('visudo')
        ["", "syntax error", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute

      assert result.failure?
      # Verify that rm command was run after validation failure
      assert commands_run.any? { |cmd| cmd.include?('rm') && cmd.include?('xmrig-orchestrator') },
             "Expected rm command to clean up invalid sudoers file"
    end
  end

  def test_completed_returns_true_when_file_exists_with_correct_permissions
    @configurator.stub :file_exists?, true do
      @configurator.stub :file_has_mode?, true do
        assert @configurator.completed?, "Should be completed when file exists with correct permissions"
      end
    end
  end

  def test_completed_returns_false_when_file_missing
    @configurator.stub :file_exists?, false do
      refute @configurator.completed?, "Should not be completed when file is missing"
    end
  end

  def test_completed_returns_false_when_permissions_incorrect
    @configurator.stub :file_exists?, true do
      @configurator.stub :file_has_mode?, false do
        refute @configurator.completed?, "Should not be completed when permissions are incorrect"
      end
    end
  end

  def test_sudoers_content_includes_required_commands
    content = Installer::SudoConfigurator::SUDOERS_CONTENT

    assert_includes content, "systemctl start xmrig"
    assert_includes content, "systemctl stop xmrig"
    assert_includes content, "systemctl restart xmrig"
    assert_includes content, "systemctl is-active xmrig"
    assert_includes content, "systemctl status xmrig"
    assert_includes content, "NOPASSWD"
    assert_includes content, "xmrig-orchestrator"
  end

  def test_sudoers_file_path_is_correct
    assert_equal '/etc/sudoers.d/xmrig-orchestrator', Installer::SudoConfigurator::SUDOERS_FILE
  end

  def test_required_mode_is_0440
    assert_equal '0440', Installer::SudoConfigurator::REQUIRED_MODE
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
