# frozen_string_literal: true

require_relative 'result'
require_relative 'base_step'

module Installer
  # Orchestrator for installation process
  # Sequences all installation steps and handles errors
  class Orchestrator
    attr_reader :logger, :results

    # Installation steps in execution order
    # Note: Step classes will be loaded dynamically when needed
    STEP_CLASSES = %w[
      PrerequisiteChecker
      UserManager
      SudoConfigurator
      DirectoryManager
      ConfigGenerator
      DaemonInstaller
      SystemdInstaller
      LogrotateConfigurator
    ].freeze

    def initialize(logger:)
      @logger = logger
      @results = []
    end

    # Execute all installation steps
    # @return [Boolean] true if all steps succeed, false otherwise
    def execute
      logger.info "=========================================="
      logger.info "XMRig Orchestrator Installation"
      logger.info "=========================================="
      logger.info ""

      load_step_classes

      steps = instantiate_steps
      total_steps = steps.length

      steps.each_with_index do |step, index|
        step_number = index + 1
        description = step.description

        # Check if step is already completed (idempotency)
        if step.completed?
          logger.info "[#{step_number}/#{total_steps}] #{description}... ✓ Already completed"
          results << Result.success("#{description} (skipped - already completed)")
          next
        end

        # Execute step
        logger.info "[#{step_number}/#{total_steps}] #{description}..."

        result = step.execute

        if result.success?
          logger.info "   ✓ #{result.message}"
          results << result
        else
          logger.error "   ✗ #{result.message}"
          results << result
          return false
        end
      end

      display_completion_message
      true
    rescue => e
      logger.error "Installation failed with error: #{e.message}"
      logger.error e.backtrace.join("\n") if ENV['DEBUG']
      false
    end

    private

    # Load step class files dynamically
    def load_step_classes
      STEP_CLASSES.each do |class_name|
        filename = class_name.gsub(/([A-Z])/) { "_#{$1}" }.downcase.sub(/^_/, '')
        require_relative filename
      end
    end

    # Instantiate all step classes
    # @return [Array<BaseStep>] array of step instances
    def instantiate_steps
      STEP_CLASSES.map do |class_name|
        klass = Installer.const_get(class_name)
        klass.new(logger: logger)
      end
    end

    # Display completion message with next steps
    def display_completion_message
      logger.info ""
      logger.info "=========================================="
      logger.info "Installation Complete!"
      logger.info "=========================================="
      logger.info ""
      logger.info "Next steps:"
      logger.info ""
      logger.info "  1. Deploy Rails application via Kamal (from local machine):"
      logger.info "     kamal deploy"
      logger.info ""
      logger.info "  2. Initialize database (first deploy only):"
      logger.info "     kamal app exec 'bin/rails db:migrate'"
      logger.info ""
      logger.info "  3. Start the orchestrator on this host:"
      logger.info "     sudo systemctl start xmrig-orchestrator"
      logger.info ""
      logger.info "  4. Check orchestrator status:"
      logger.info "     sudo systemctl status xmrig-orchestrator"
      logger.info "     sudo journalctl -u xmrig-orchestrator -f"
      logger.info ""
      logger.info "  5. Issue start command from Rails:"
      logger.info "     Xmrig::CommandService.start_mining"
      logger.info ""
      logger.info "Database location: /mnt/rails-storage/production.sqlite3"
      logger.info "  (will be created by Rails on first deploy)"
      logger.info ""
    end
  end
end
