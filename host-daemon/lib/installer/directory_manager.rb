# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # Directory and file management step
  # Creates required directories and files with correct ownership and permissions
  class DirectoryManager < BaseStep
    DIRECTORIES = [
      { path: '/var/log/xmrig', owner: 'xmrig', group: 'xmrig', mode: '0755' },
      { path: '/etc/xmrig', owner: 'root', group: 'root', mode: '0755' },
      { path: '/var/lib/xmrig-orchestrator/gems', owner: 'xmrig-orchestrator', group: 'xmrig-orchestrator', mode: '0755' },
      { path: '/mnt/rails-storage', owner: '1000', group: 'deploy', mode: '2775' }
    ].freeze

    FILES = [
      { path: '/var/log/xmrig/orchestrator.log', owner: 'xmrig-orchestrator', group: 'xmrig-orchestrator', mode: '0644' }
    ].freeze

    def execute
      # Create directories
      DIRECTORIES.each do |dir_info|
        result = create_directory(dir_info)
        return result if result.failure?
      end

      # Create files
      FILES.each do |file_info|
        result = create_file(file_info)
        return result if result.failure?
      end

      Result.success("All directories and files created")
    end

    private

    def create_directory(dir_info)
      path = dir_info[:path]
      owner = dir_info[:owner]
      group = dir_info[:group]
      mode = dir_info[:mode]

      # Create directory if it doesn't exist
      unless file_exists?(path)
        result = sudo_execute('mkdir', '-p', path, error_prefix: "Failed to create directory #{path}")
        return result if result.failure?
        logger.info "   ✓ Created directory #{path}"
      end

      # Set ownership
      result = sudo_execute('chown', "#{owner}:#{group}", path, error_prefix: "Failed to set ownership for #{path}")
      return result if result.failure?

      # Set permissions
      result = sudo_execute('chmod', mode, path, error_prefix: "Failed to set permissions for #{path}")
      return result if result.failure?

      logger.info "   ✓ Directory #{path} configured (#{owner}:#{group}, #{mode})" if file_exists?(path)
      Result.success("Directory #{path} configured")
    end

    def create_file(file_info)
      path = file_info[:path]
      owner = file_info[:owner]
      group = file_info[:group]
      mode = file_info[:mode]

      # Create file if it doesn't exist
      unless file_exists?(path)
        result = sudo_execute('touch', path, error_prefix: "Failed to create file #{path}")
        return result if result.failure?
        logger.info "   ✓ Created file #{path}"
      end

      # Set ownership
      result = sudo_execute('chown', "#{owner}:#{group}", path, error_prefix: "Failed to set ownership for #{path}")
      return result if result.failure?

      # Set permissions
      result = sudo_execute('chmod', mode, path, error_prefix: "Failed to set permissions for #{path}")
      return result if result.failure?

      logger.info "   ✓ File #{path} configured (#{owner}:#{group}, #{mode})" if file_exists?(path)
      Result.success("File #{path} configured")
    end
  end
end
