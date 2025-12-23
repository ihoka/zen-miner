# frozen_string_literal: true

require 'json'
require_relative 'base_step'

module Installer
  # XMRig configuration file generator
  # Generates /etc/xmrig/config.json from environment variables
  class ConfigGenerator < BaseStep
    CONFIG_FILE = '/etc/xmrig/config.json'
    DEFAULT_POOL_URL = 'pool.hashvault.pro:443'
    DEFAULT_CPU_MAX_THREADS_HINT = 50

    def execute
      # Get environment variables
      wallet = ENV['MONERO_WALLET']
      worker_id = ENV['WORKER_ID']
      pool_url = ENV.fetch('POOL_URL', DEFAULT_POOL_URL)
      cpu_max_threads = ENV.fetch('CPU_MAX_THREADS_HINT', DEFAULT_CPU_MAX_THREADS_HINT).to_i

      # Generate config
      config = generate_config(wallet, worker_id, pool_url, cpu_max_threads)

      # Write config file
      result = write_config_file(config)
      return result if result.failure?

      logger.info "   ✓ XMRig config written to #{CONFIG_FILE}"
      Result.success("XMRig configuration generated")
    end

    def completed?
      file_exists?(CONFIG_FILE)
    end

    private

    def generate_config(wallet, worker_id, pool_url, cpu_max_threads)
      {
        "autosave" => true,
        "http" => {
          "enabled" => true,
          "host" => "127.0.0.1",
          "port" => 8080,
          "access-token" => nil,
          "restricted" => true
        },
        "pools" => [
          {
            "url" => pool_url,
            "user" => wallet,
            "pass" => worker_id,
            "rig-id" => worker_id,
            "tls" => true,
            "keepalive" => true
          }
        ],
        "cpu" => {
          "enabled" => true,
          "huge-pages" => true,
          "priority" => 1,
          "max-threads-hint" => cpu_max_threads
        },
        "opencl" => { "enabled" => false },
        "cuda" => { "enabled" => false },
        "donate-level" => 1
      }
    end

    def write_config_file(config)
      # Generate JSON with pretty formatting
      json_content = JSON.pretty_generate(config)

      # Write to temporary file first
      temp_file = "#{CONFIG_FILE}.tmp"

      # Use heredoc to write JSON content safely
      result = run_command('sudo', 'bash', '-c', "cat > #{temp_file} <<'EOF'\n#{json_content}\nEOF")

      unless result[:success]
        return Result.failure(
          "Failed to write config file: #{result[:stderr]}",
          data: { file: temp_file, error: result[:stderr] }
        )
      end

      # Move to final location
      result = run_command('sudo', 'mv', temp_file, CONFIG_FILE)

      unless result[:success]
        return Result.failure(
          "Failed to move config file to final location: #{result[:stderr]}",
          data: { error: result[:stderr] }
        )
      end

      Result.success("Config file written successfully")
    end
  end
end
