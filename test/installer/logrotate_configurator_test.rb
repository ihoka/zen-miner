# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/logrotate_configurator'

class LogrotateConfiguratorTest < Minitest::Test
  def setup
    @logger = mock_logger
    @configurator = Installer::LogrotateConfigurator.new(logger: @logger)
  end

  def test_execute_success_when_logrotate_configured
    Open3.stub :capture3, lambda { |*args|
      ["", "", mock_status(true)]
    } do
      result = @configurator.execute

      assert result.success?
      assert_equal "Logrotate configured", result.message

      # Verify logging
      messages = @logger.messages.map { |_, msg| msg }
      assert messages.any? { |msg| msg.include?("Logrotate file written") }
      assert messages.any? { |msg| msg.include?("7 day retention") }
    end
  end

  def test_execute_fails_when_write_fails
    Open3.stub :capture3, lambda { |*args|
      ["", "Permission denied", mock_status(false)]
    } do
      result = @configurator.execute

      assert result.failure?
      assert_includes result.message, "Failed to write logrotate configuration"
      assert_includes result.message, "Permission denied"
    end
  end

  def test_logrotate_config_includes_required_settings
    config = Installer::LogrotateConfigurator::LOGROTATE_CONFIG

    assert_includes config, "/var/log/xmrig/*.log"
    assert_includes config, "daily"
    assert_includes config, "rotate 7"
    assert_includes config, "compress"
    assert_includes config, "missingok"
    assert_includes config, "notifempty"
    assert_includes config, "create 0640 xmrig xmrig"
  end

  def test_logrotate_file_path_is_correct
    assert_equal '/etc/logrotate.d/xmrig', Installer::LogrotateConfigurator::LOGROTATE_FILE
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
