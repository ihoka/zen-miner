# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/user_manager'

class UserManagerTest < Minitest::Test
  def setup
    @logger = mock_logger
    @manager = Installer::UserManager.new(logger: @logger)
  end

  def test_execute_success_when_all_users_and_groups_configured
    # Mock all checks to succeed
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator deploy", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.success?
        assert_equal "All users and groups configured", result.message
      end
    end
  end

  def test_execute_creates_missing_users
    # Mock xmrig exists, but xmrig-orchestrator doesn't
    @manager.stub :user_exists?, lambda { |user| user == 'xmrig' } do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('useradd')
          ["", "", mock_status(true)]
        elsif cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator deploy", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.success?

        # Verify logger shows user creation
        messages = @logger.messages.map { |_, msg| msg }
        assert messages.any? { |msg| msg.include?("User 'xmrig' already exists") }
        assert messages.any? { |msg| msg.include?("User 'xmrig-orchestrator' created") }
      end
    end
  end

  def test_execute_fails_when_user_creation_fails
    @manager.stub :user_exists?, false do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('useradd')
          ["", "Permission denied", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to create user"
        assert_includes result.message, "Permission denied"
      end
    end
  end

  def test_execute_creates_deploy_group_if_missing
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["", "", mock_status(false)]  # Group doesn't exist
        elsif cmd.include?('groupadd deploy')
          ["", "", mock_status(true)]   # Create succeeds
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator deploy", "", mock_status(true)]
        elsif cmd.include?('usermod')
          ["", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.success?

        # Verify logger shows group creation
        messages = @logger.messages.map { |_, msg| msg }
        assert messages.any? { |msg| msg.include?("Created 'deploy' group") }
      end
    end
  end

  def test_execute_fails_when_group_creation_fails
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["", "", mock_status(false)]
        elsif cmd.include?('groupadd')
          ["", "Group already exists", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to create group 'deploy'"
      end
    end
  end

  def test_execute_adds_orchestrator_to_deploy_group
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator') && !cmd.include?('usermod')
          # First check: not in group
          ["xmrig-orchestrator : xmrig-orchestrator", "", mock_status(true)]
        elsif cmd.include?('usermod')
          ["", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.success?

        # Verify logger shows user added to group
        messages = @logger.messages.map { |_, msg| msg }
        assert messages.any? { |msg| msg.include?("Added 'xmrig-orchestrator' to 'deploy' group") }
      end
    end
  end

  def test_execute_fails_when_usermod_fails
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator", "", mock_status(true)]
        elsif cmd.include?('usermod')
          ["", "User not found", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @manager.execute

        assert result.failure?
        assert_includes result.message, "Failed to add user"
      end
    end
  end

  def test_completed_returns_true_when_all_configured
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator deploy", "", mock_status(true)]
        else
          ["", "", mock_status(true)]
        end
      } do
        assert @manager.completed?, "Should be completed when all users and groups exist"
      end
    end
  end

  def test_completed_returns_false_when_users_missing
    @manager.stub :user_exists?, false do
      refute @manager.completed?, "Should not be completed when users are missing"
    end
  end

  def test_completed_returns_false_when_group_missing
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["", "", mock_status(false)]  # Group doesn't exist
        else
          ["", "", mock_status(true)]
        end
      } do
        refute @manager.completed?, "Should not be completed when deploy group is missing"
      end
    end
  end

  def test_completed_returns_false_when_orchestrator_not_in_group
    @manager.stub :user_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('getent group deploy')
          ["deploy:x:1001:", "", mock_status(true)]
        elsif cmd.include?('groups xmrig-orchestrator')
          ["xmrig-orchestrator : xmrig-orchestrator", "", mock_status(true)]  # Not in deploy group
        else
          ["", "", mock_status(true)]
        end
      } do
        refute @manager.completed?, "Should not be completed when orchestrator not in deploy group"
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
