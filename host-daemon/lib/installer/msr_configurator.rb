# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # MSR (Model Specific Register) configuration step
  # Enables XMRig to apply CPU-level optimizations for RandomX mining,
  # which significantly improves hashrate.
  #
  # This step:
  # 1. Loads the msr kernel module
  # 2. Ensures it loads at boot via /etc/modules-load.d/
  # 3. Adds a udev rule so /dev/cpu/*/msr devices are accessible to the xmrig group
  # 4. Grants CAP_SYS_RAWIO to the xmrig binary
  # 5. Triggers udev to apply new rules immediately
  class MsrConfigurator < BaseStep
    MSR_MODULE = 'msr'
    MODULES_LOAD_CONF = '/etc/modules-load.d/msr.conf'
    UDEV_RULE_PATH = '/etc/udev/rules.d/99-msr.rules'
    UDEV_RULE = 'KERNEL=="msr[0-9]*", MODE="0660", GROUP="xmrig"'
    XMRIG_BINARY = '/usr/local/bin/xmrig'

    def execute
      result = load_msr_module
      return result if result.failure?

      result = configure_msr_at_boot
      return result if result.failure?

      result = install_udev_rule
      return result if result.failure?

      result = grant_capability
      return result if result.failure?

      result = apply_udev_rules
      return result if result.failure?

      Result.success("MSR access configured for XMRig")
    end

    private

    def load_msr_module
      result = run_command('lsmod')
      if result[:success] && result[:stdout].include?('msr')
        logger.info "   ✓ MSR kernel module already loaded"
        return Result.success("MSR module loaded")
      end

      sudo_execute('modprobe', MSR_MODULE, error_prefix: "Failed to load MSR module")
        .tap { |r| logger.info "   ✓ MSR kernel module loaded" if r.success? }
    end

    def configure_msr_at_boot
      if file_exists?(MODULES_LOAD_CONF)
        logger.info "   ✓ MSR module already configured for boot"
        return Result.success("MSR boot config exists")
      end

      result = run_command('sudo', 'tee', MODULES_LOAD_CONF, stdin_data: "#{MSR_MODULE}\n")
      # tee via Open3 doesn't support stdin_data, use shell write instead
      result = run_command('sudo', 'sh', '-c', "echo '#{MSR_MODULE}' > #{MODULES_LOAD_CONF}")

      if result[:success]
        logger.info "   ✓ MSR module configured to load at boot"
        Result.success("MSR boot config created")
      else
        Result.failure("Failed to configure MSR at boot: #{result[:stderr]}")
      end
    end

    def install_udev_rule
      if file_exists?(UDEV_RULE_PATH)
        logger.info "   ✓ MSR udev rule already installed"
        return Result.success("udev rule exists")
      end

      result = run_command('sudo', 'sh', '-c', "echo '#{UDEV_RULE}' > #{UDEV_RULE_PATH}")

      if result[:success]
        logger.info "   ✓ MSR udev rule installed"
        Result.success("udev rule installed")
      else
        Result.failure("Failed to install udev rule: #{result[:stderr]}")
      end
    end

    def grant_capability
      # Check if capability is already set
      result = run_command('getcap', XMRIG_BINARY)
      if result[:success] && result[:stdout].include?('cap_sys_rawio')
        logger.info "   ✓ CAP_SYS_RAWIO already set on xmrig"
        return Result.success("Capability already set")
      end

      sudo_execute('setcap', 'cap_sys_rawio+ep', XMRIG_BINARY,
                   error_prefix: "Failed to set CAP_SYS_RAWIO on xmrig")
        .tap { |r| logger.info "   ✓ CAP_SYS_RAWIO granted to xmrig" if r.success? }
    end

    def apply_udev_rules
      result = run_command('sudo', 'udevadm', 'control', '--reload-rules')
      return Result.failure("Failed to reload udev rules: #{result[:stderr]}") unless result[:success]

      result = run_command('sudo', 'udevadm', 'trigger')
      return Result.failure("Failed to trigger udev: #{result[:stderr]}") unless result[:success]

      logger.info "   ✓ udev rules applied"
      Result.success("udev rules applied")
    end
  end
end
