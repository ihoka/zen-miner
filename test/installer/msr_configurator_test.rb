# frozen_string_literal: true

require_relative "test_helper"
require_relative "../../host-daemon/lib/installer/msr_configurator"

class MsrConfiguratorTest < Minitest::Test
  def setup
    @logger = mock_logger
    @configurator = Installer::MsrConfigurator.new(logger: @logger)
  end

  def test_execute_success_when_all_steps_pass
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      if cmd.include?("lsmod")
        ["msr  12288  0\n", "", mock_status(true)]
      elsif cmd.include?("getcap")
        ["/usr/local/bin/xmrig cap_sys_rawio=ep\n", "", mock_status(true)]
      else
        ["", "", mock_status(true)]
      end
    } do
      File.stub :exist?, lambda { |path|
        ["/etc/modules-load.d/msr.conf", "/etc/udev/rules.d/99-msr.rules"].include?(path)
      } do
        result = @configurator.execute
        assert result.success?
        assert_equal "MSR access configured for XMRig", result.message
      end
    end
  end

  def test_execute_loads_msr_module_when_not_loaded
    commands_run = []

    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      commands_run << cmd
      if cmd.include?("lsmod")
        ["some_other_module  12288  0\n", "", mock_status(true)]
      elsif cmd.include?("modprobe")
        ["", "", mock_status(true)]
      elsif cmd.include?("getcap")
        ["/usr/local/bin/xmrig cap_sys_rawio=ep\n", "", mock_status(true)]
      else
        ["", "", mock_status(true)]
      end
    } do
      File.stub :exist?, lambda { |path|
        ["/etc/modules-load.d/msr.conf", "/etc/udev/rules.d/99-msr.rules"].include?(path)
      } do
        result = @configurator.execute
        assert result.success?
        assert commands_run.any? { |c| c.include?("modprobe msr") }
      end
    end
  end

  def test_execute_fails_when_modprobe_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      if cmd.include?("lsmod")
        ["", "", mock_status(true)]
      elsif cmd.include?("modprobe")
        ["", "modprobe: FATAL: Module msr not found", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      result = @configurator.execute
      assert result.failure?
      assert_includes result.message, "Failed to load MSR module"
    end
  end

  def test_execute_grants_capability_when_not_set
    commands_run = []

    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      commands_run << cmd
      if cmd.include?("lsmod")
        ["msr  12288  0\n", "", mock_status(true)]
      elsif cmd.include?("getcap")
        ["/usr/local/bin/xmrig\n", "", mock_status(true)]
      else
        ["", "", mock_status(true)]
      end
    } do
      File.stub :exist?, lambda { |path|
        ["/etc/modules-load.d/msr.conf", "/etc/udev/rules.d/99-msr.rules"].include?(path)
      } do
        result = @configurator.execute
        assert result.success?
        assert commands_run.any? { |c| c.include?("setcap") && c.include?("cap_sys_rawio") }
      end
    end
  end

  def test_execute_skips_existing_udev_rule
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      if cmd.include?("lsmod")
        ["msr  12288  0\n", "", mock_status(true)]
      elsif cmd.include?("getcap")
        ["/usr/local/bin/xmrig cap_sys_rawio=ep\n", "", mock_status(true)]
      else
        ["", "", mock_status(true)]
      end
    } do
      File.stub :exist?, lambda { |path|
        ["/etc/modules-load.d/msr.conf", "/etc/udev/rules.d/99-msr.rules"].include?(path)
      } do
        result = @configurator.execute
        assert result.success?

        messages = @logger.messages.map { |_, msg| msg }
        assert messages.any? { |msg| msg.include?("udev rule already installed") }
      end
    end
  end

  def test_execute_fails_when_udev_reload_fails
    Open3.stub :capture3, lambda { |*args|
      cmd = args.join(" ")
      if cmd.include?("lsmod")
        ["msr  12288  0\n", "", mock_status(true)]
      elsif cmd.include?("getcap")
        ["/usr/local/bin/xmrig cap_sys_rawio=ep\n", "", mock_status(true)]
      elsif cmd.include?("udevadm control")
        ["", "Failed to reload", mock_status(false)]
      else
        ["", "", mock_status(true)]
      end
    } do
      File.stub :exist?, lambda { |path|
        ["/etc/modules-load.d/msr.conf", "/etc/udev/rules.d/99-msr.rules"].include?(path)
      } do
        result = @configurator.execute
        assert result.failure?
        assert_includes result.message, "Failed to reload udev rules"
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
