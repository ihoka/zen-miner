# frozen_string_literal: true

require_relative 'base_step'

module Installer
  # User and group management step
  # Creates system users and groups needed for the installation
  class UserManager < BaseStep
    USERS = [
      { name: 'xmrig', description: 'XMRig service user' },
      { name: 'xmrig-orchestrator', description: 'Orchestrator service user' }
    ].freeze

    DEPLOY_GROUP = 'deploy'

    def execute
      # Create system users
      USERS.each do |user_info|
        result = create_user(user_info[:name], user_info[:description])
        return result if result.failure?
      end

      # Create deploy group
      result = create_deploy_group
      return result if result.failure?

      # Add orchestrator to deploy group
      result = add_user_to_group('xmrig-orchestrator', DEPLOY_GROUP)
      return result if result.failure?

      Result.success("All users and groups configured")
    end

    private

    def all_users_exist?
      USERS.all? { |user_info| user_exists?(user_info[:name]) }
    end

    def group_exists?(group_name)
      result = run_command('getent', 'group', group_name)
      result[:success]
    end

    def user_in_group?(username, group_name)
      result = run_command('groups', username)
      return false unless result[:success]

      result[:stdout].include?(group_name)
    end

    def create_user(username, description)
      if user_exists?(username)
        logger.info "   ✓ User '#{username}' already exists"
        return Result.success("User '#{username}' already exists")
      end

      result = sudo_execute('useradd', '-r', '-s', '/bin/false', username,
                           error_prefix: "Failed to create user '#{username}'")
      return result if result.failure?

      logger.info "   ✓ User '#{username}' created"
      Result.success("User '#{username}' created")
    end

    def create_deploy_group
      if group_exists?(DEPLOY_GROUP)
        logger.info "   ✓ Group '#{DEPLOY_GROUP}' already exists"
        return Result.success("Group '#{DEPLOY_GROUP}' already exists")
      end

      result = sudo_execute('groupadd', DEPLOY_GROUP,
                           error_prefix: "Failed to create group '#{DEPLOY_GROUP}'")
      return result if result.failure?

      logger.info "   ✓ Created '#{DEPLOY_GROUP}' group"
      Result.success("Created '#{DEPLOY_GROUP}' group")
    end

    def add_user_to_group(username, group_name)
      if user_in_group?(username, group_name)
        logger.info "   ✓ User '#{username}' already in group '#{group_name}'"
        return Result.success("User '#{username}' already in group '#{group_name}'")
      end

      result = sudo_execute('usermod', '-a', '-G', group_name, username,
                           error_prefix: "Failed to add user '#{username}' to group '#{group_name}'")
      return result if result.failure?

      logger.info "   ✓ Added '#{username}' to '#{group_name}' group"
      Result.success("Added '#{username}' to '#{group_name}' group")
    end
  end
end
