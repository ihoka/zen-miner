# frozen_string_literal: true

require "yaml"
require "open3"
require "optparse"
require "shellwords"

module OrchestratorUpdater
  # Custom exceptions
  class ConfigError < StandardError; end
  class HostnameError < StandardError; end

  # Parses config/deploy.yml and extracts hosts
  class Config
    CONFIG_PATH = "config/deploy.yml"

    def self.load_hosts
      config = YAML.load_file(CONFIG_PATH)
      hosts = config.dig("servers", "web", "hosts")

      raise ConfigError, "No hosts found in config" if hosts.nil? || hosts.empty?

      hosts
    rescue Errno::ENOENT
      raise ConfigError, "Config file not found: #{CONFIG_PATH}"
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in config file: #{e.message}"
    end
  end

  # Validates hostname format (RFC 952/1123 compliant, prevents injection)
  class HostValidator
    # Each label must:
    # - Start with alphanumeric
    # - End with alphanumeric
    # - Contain only alphanumeric and hyphens in between
    # - Be max 63 characters
    LABEL_REGEX = /\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/
    MAX_HOSTNAME_LENGTH = 253

    def self.valid?(hostname)
      return false if hostname.nil? || hostname.to_s.empty?
      return false if hostname.length > MAX_HOSTNAME_LENGTH

      # Split into labels and validate each one
      labels = hostname.split('.')
      return false if labels.empty?
      return false if labels.any? { |label| !label.match?(LABEL_REGEX) }

      true
    end
  end

  # Handles SSH operations for a single host
  class SSHExecutor
    attr_reader :hostname

    def initialize(hostname, dry_run: false, verbose: false)
      @hostname = hostname
      @dry_run = dry_run
      @verbose = verbose
      @ssh_user = "deploy"
      @temp_prefix = "/tmp/xmrig-orchestrator-#{Process.pid}"
    end

    def check_connectivity
      return true if @dry_run

      stdout, _stderr, status = ssh("echo ok")
      status.success? && stdout.strip == "ok"
    end

    def copy_orchestrator(source_path)
      return true if @dry_run

      destination = "#{@temp_prefix}-#{@hostname}"
      _stdout, _stderr, status = scp(source_path, destination)
      status.success?
    end

    def update_orchestrator
      if @dry_run
        return {
          success: true,
          output: "[DRY RUN] Would update orchestrator on #{@hostname}",
          error: ""
        }
      end

      temp_file = "#{@temp_prefix}-#{@hostname}"

      update_script = <<~BASH
        set -e

        # 1. Detect xmrig binary location
        XMRIG_PATH=$(which xmrig 2>/dev/null || echo "")
        if [ -n "$XMRIG_PATH" ] && [ "$XMRIG_PATH" != "/usr/local/bin/xmrig" ]; then
          echo "  ✓ XMRig detected at: $XMRIG_PATH"
          sudo ln -sf "$XMRIG_PATH" /usr/local/bin/xmrig
          echo "  ✓ Symlink created: /usr/local/bin/xmrig"
        elif [ -z "$XMRIG_PATH" ]; then
          echo "  ⚠ Warning: xmrig not found in PATH"
        else
          echo "  ✓ XMRig already at /usr/local/bin/xmrig"
        fi

        # 2. Install orchestrator
        sudo cp #{temp_file} /usr/local/bin/xmrig-orchestrator
        sudo chmod +x /usr/local/bin/xmrig-orchestrator
        echo "  ✓ Orchestrator updated"

        # 3. Restart service
        sudo systemctl restart xmrig-orchestrator
        sleep 2

        # 4. Verify running
        if sudo systemctl is-active --quiet xmrig-orchestrator; then
          echo "  ✓ Service verified"
        else
          echo "  ✗ Service failed to start"
          sudo journalctl -u xmrig-orchestrator -n 10 --no-pager
          exit 1
        fi

        # 5. Cleanup
        rm -f #{temp_file}
      BASH

      stdout, stderr, status = ssh(update_script)

      {
        success: status.success?,
        output: stdout,
        error: stderr
      }
    end

    def verify_service
      return true if @dry_run

      _stdout, _stderr, status = ssh("sudo systemctl is-active xmrig-orchestrator")
      status.success?
    end

    private

    def ssh(command)
      # Use array form to prevent shell interpretation
      ssh_args = [
        'ssh',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=yes',  # Require known host key
        "#{@ssh_user}@#{@hostname}",
        command
      ]

      log_command(ssh_args.join(' ')) if @verbose

      Open3.capture3(*ssh_args)
    end

    def scp(source, destination)
      # Use array form to prevent shell interpretation
      scp_args = [
        'scp',
        '-q',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=yes',  # Require known host key
        source,
        "#{@ssh_user}@#{@hostname}:#{destination}"
      ]

      log_command(scp_args.join(' ')) if @verbose

      Open3.capture3(*scp_args)
    end

    def log_command(command)
      puts "[#{Time.now.strftime('%H:%M:%S')}] Executing: #{command}"
    end
  end

  # Orchestrates updates across all hosts
  class UpdateCoordinator
    SOURCE_FILE = "host-daemon/xmrig-orchestrator"

    def initialize(hosts, options = {})
      @hosts = hosts
      @options = options
      @results = { success: [], failed: [] }
      @start_time = Time.now
    end

    def run
      display_header
      return 1 unless preflight_checks
      return 1 unless confirm_update

      update_all_hosts
      display_summary

      @results[:failed].empty? ? 0 : 1
    end

    private

    def preflight_checks
      # Verify source file exists
      unless File.exist?(SOURCE_FILE)
        puts "ERROR: Source file not found: #{SOURCE_FILE}"
        return false
      end

      if File.symlink?(SOURCE_FILE)
        puts "ERROR: Source file is a symlink: #{SOURCE_FILE}"
        return false
      end

      true
    end

    def confirm_update
      return true if @options[:yes] || @options[:dry_run]

      puts
      print "Continue? [y/N]: "
      response = $stdin.gets.to_s.chomp
      response.match?(/^[Yy]/)
    end

    def update_all_hosts
      @hosts.each do |hostname|
        update_host(hostname)
      end
    end

    def update_host(hostname)
      puts
      puts "=" * 40
      puts "Updating: #{hostname}"
      puts "=" * 40

      executor = SSHExecutor.new(hostname, dry_run: @options[:dry_run], verbose: @options[:verbose])
      step_start = Time.now

      # Step 1: Check connectivity
      print "[#{timestamp}] Checking SSH connectivity..."
      unless executor.check_connectivity
        puts " ✗ FAILED"
        @results[:failed] << { host: hostname, reason: "SSH connection failed" }
        return
      end
      puts " ✓"

      # Step 2: Copy orchestrator
      print "[#{timestamp}] Copying orchestrator file..."
      unless executor.copy_orchestrator(SOURCE_FILE)
        puts " ✗ FAILED"
        @results[:failed] << { host: hostname, reason: "SCP transfer failed" }
        return
      end
      puts " ✓"

      # Step 3: Execute update
      print "[#{timestamp}] Executing update commands..."
      result = executor.update_orchestrator
      unless result[:success]
        puts " ✗ FAILED"
        puts
        puts "Output: #{result[:output]}" unless result[:output].empty?
        puts "Error: #{result[:error]}" unless result[:error].empty?
        @results[:failed] << { host: hostname, reason: "Update commands failed" }
        return
      end
      puts " ✓"

      # Print update output
      puts result[:output] unless result[:output].empty?

      # Step 4: Verify service
      print "[#{timestamp}] Verifying service status..."
      unless executor.verify_service
        puts " ✗ FAILED"
        @results[:failed] << { host: hostname, reason: "Service verification failed" }
        return
      end
      puts " ✓"

      elapsed = Time.now - step_start
      puts
      puts "✓ #{hostname} updated successfully (#{elapsed.round(1)}s)"

      @results[:success] << hostname
    end

    def display_header
      puts
      puts "=" * 60
      puts "XMRig Orchestrator Update (via SSH)"
      puts "=" * 60
      puts

      if @options[:dry_run]
        puts "MODE: DRY RUN (no changes will be made)"
        puts
      end

      puts "Hosts to update:"
      @hosts.each do |host|
        puts "  - #{host}"
      end
      puts
      puts "Source: #{File.expand_path(SOURCE_FILE)}"
      puts "Update method: Direct SSH as deploy user"
    end

    def display_summary
      puts
      puts "=" * 60
      puts "Update Summary"
      puts "=" * 60
      puts

      if @results[:success].any?
        puts "Success: #{@results[:success].length} host(s)"
        @results[:success].each do |host|
          puts "  ✓ #{host}"
        end
        puts
      end

      if @results[:failed].any?
        puts "Failed: #{@results[:failed].length} host(s)"
        @results[:failed].each do |failure|
          puts "  ✗ #{failure[:host]} (#{failure[:reason]})"
        end
        puts
        puts "To retry failed hosts:"
        @results[:failed].each do |failure|
          puts "  bin/update-orchestrators-ssh --host #{failure[:host]} --yes"
        end
        puts
      end

      elapsed = Time.now - @start_time
      puts "Total time: #{elapsed.round(1)}s"
      puts
    end

    def timestamp
      Time.now.strftime("%H:%M:%S")
    end
  end

  # Command-line interface
  class CLI
    def self.run(argv)
      options = parse_options(argv)
      hosts = determine_hosts(options)

      # Validate source file
      unless File.exist?("host-daemon/xmrig-orchestrator")
        puts "ERROR: Source file not found: host-daemon/xmrig-orchestrator"
        exit 1
      end

      coordinator = UpdateCoordinator.new(hosts, options)
      exit coordinator.run
    rescue ConfigError, HostnameError => e
      puts "ERROR: #{e.message}"
      exit 1
    end

    private

    def self.parse_options(argv)
      options = {
        host: nil,
        yes: false,
        dry_run: false,
        verbose: false
      }

      OptionParser.new do |opts|
        opts.banner = "Usage: bin/update-orchestrators-ssh [options]"

        opts.on("--host HOSTNAME", "Update specific host only") do |h|
          options[:host] = h
        end

        opts.on("--yes", "Skip confirmation prompt") do
          options[:yes] = true
        end

        opts.on("--dry-run", "Show commands without executing") do
          options[:dry_run] = true
        end

        opts.on("--verbose", "Show all SSH commands") do
          options[:verbose] = true
        end

        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit 0
        end
      end.parse!(argv)

      options
    rescue OptionParser::InvalidOption => e
      puts "ERROR: #{e.message}"
      puts "Run with --help for usage information"
      exit 1
    end

    def self.determine_hosts(options)
      # If --host specified, use single host
      if options[:host]
        hostname = options[:host]
        unless HostValidator.valid?(hostname)
          raise HostnameError, "Invalid hostname: #{hostname}"
        end
        return [hostname]
      end

      # Otherwise load from config
      hosts = Config.load_hosts

      # Validate all hostnames
      hosts.each do |hostname|
        unless HostValidator.valid?(hostname)
          raise HostnameError, "Invalid hostname in config: #{hostname}"
        end
      end

      hosts
    end
  end
end
