# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/sudo_configurator'

class SudoConfiguratorTest < Minitest::Test
  def setup
    @logger = mock_logger
    @configurator = Installer::SudoConfigurator.new(logger: @logger)
  end

  def test_execute_success_when_sudoers_configured
    original_umask = File.umask
    File.stub :open, lambda { |path, *args, &block|
      # Mock file writing - just yield a mock file object
      mock_file = Object.new
      mock_file.define_singleton_method(:write) { |content| content.length }
      block.call(mock_file) if block
    } do
      File.stub :umask, lambda { |new_mask = nil| new_mask ? original_umask : original_umask } do
        File.stub :unlink, lambda { |path| true } do
          Open3.stub :capture3, lambda { |*args|
            # Return appropriate stdout for stat command
            if args.include?('stat')
              ["root:root:440\n", "", mock_status(true)]
            else
              ["", "", mock_status(true)]
            end
          } do
            File.stub :exist?, false do
              result = @configurator.execute

              assert result.success?
              assert_equal "Sudoers file installed securely", result.message

              # Verify all steps were logged
              messages = @logger.messages.map { |_, msg| msg }
              assert messages.any? { |msg| msg.include?("Sudoers file written") }
              assert messages.any? { |msg| msg.include?("Sudo permissions configured") }
              assert messages.any? { |msg| msg.include?("Sudoers syntax validated") }
            end
          end
        end
      end
    end
  end

  def test_execute_fails_when_write_fails
    File.stub :open, lambda { |*args, &block|
      raise Errno::EACCES, "Permission denied @ rb_sysopen - /etc/sudoers.d/xmrig-orchestrator.tmp.#{Process.pid}"
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Failed to create sudoers file"
      assert_includes result.message, "Permission denied"
    end
  end

  def test_execute_fails_when_chmod_fails
    # This test is no longer relevant since we use File.open with mode parameter
    # which sets permissions atomically during file creation
    skip "chmod is now atomic with file creation"
  end

  def test_execute_fails_when_install_fails
    File.stub :open, lambda { |*args, &block|
      mock_file = Object.new
      mock_file.define_singleton_method(:write) { |content| content.length }
      block.call(mock_file) if block
    } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('install')
          ["", "Cannot install file", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        File.stub :exist?, false do
          result = @configurator.execute

          assert result.failure?
          assert_includes result.message, "Failed to install sudoers file"
          assert_includes result.message, "Cannot install file"
        end
      end
    end
  end

  def test_execute_fails_when_visudo_validation_fails
    File.stub :open, lambda { |*args, &block|
      mock_file = Object.new
      mock_file.define_singleton_method(:write) { |content| content.length }
      block.call(mock_file) if block
    } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('visudo')
          ["", "syntax error on line 2", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        File.stub :exist?, true do
          File.stub :unlink, nil do
            result = @configurator.execute

            assert result.failure?
            assert_includes result.message, "Invalid sudoers syntax"
            assert_includes result.message, "syntax error"
          end
        end
      end
    end
  end

  def test_execute_removes_file_on_validation_failure
    file_unlinked = false

    File.stub :open, lambda { |*args, &block|
      mock_file = Object.new
      mock_file.define_singleton_method(:write) { |content| content.length }
      block.call(mock_file) if block
    } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('visudo')
          ["", "syntax error", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        File.stub :exist?, true do
          File.stub :unlink, lambda { |path| file_unlinked = true } do
            result = @configurator.execute

            assert result.failure?
            # Verify that File.unlink was called in ensure block
            assert file_unlinked, "Expected temp file to be cleaned up after validation failure"
          end
        end
      end
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
