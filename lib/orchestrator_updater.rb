# frozen_string_literal: true

require "yaml"
require "open3"
require "optparse"
require "shellwords"
require "concurrent-ruby"
require "timeout"
require "fileutils"
require "digest"

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

  # Manages SSH known hosts for secure host verification
  class KnownHostsManager
    KNOWN_HOSTS_FILE = "config/known_hosts"

    # Verify a host's SSH fingerprint against known hosts
    # @param hostname [String] hostname to verify
    # @param ssh_user [String] SSH user for connection
    # @return [Boolean] true if host key matches known hosts
    def self.verify_host(hostname, ssh_user: "deploy")
      return true unless File.exist?(KNOWN_HOSTS_FILE)

      # Get current host key
      current_key = get_host_key(hostname, ssh_user)
      return false unless current_key

      # Check against known hosts file
      known_hosts = File.readlines(KNOWN_HOSTS_FILE, chomp: true)
      known_hosts.any? { |line| line.start_with?(hostname) && line.include?(current_key) }
    rescue => e
      warn "Host key verification failed for #{hostname}: #{e.message}"
      false
    end

    # Add a host to known hosts file
    # @param hostname [String] hostname to add
    # @param ssh_user [String] SSH user for connection
    def self.add_host(hostname, ssh_user: "deploy")
      # Get host key
      host_key = get_host_key(hostname, ssh_user)
      return false unless host_key

      # Ensure config directory exists
      FileUtils.mkdir_p(File.dirname(KNOWN_HOSTS_FILE))

      # Create entry in known_hosts format
      entry = "#{hostname} #{host_key}"

      # Append to file (idempotent - won't add duplicates)
      existing_content = File.exist?(KNOWN_HOSTS_FILE) ? File.read(KNOWN_HOSTS_FILE) : ""
      unless existing_content.include?(entry)
        File.open(KNOWN_HOSTS_FILE, 'a') do |f|
          f.puts entry
        end
        puts "✓ Added #{hostname} to known hosts"
      end

      true
    rescue => e
      warn "Failed to add host #{hostname}: #{e.message}"
      false
    end

    # Get SSH host key fingerprint
    # @param hostname [String] hostname
    # @param ssh_user [String] SSH user
    # @return [String, nil] host key or nil if failed
    def self.get_host_key(hostname, ssh_user)
      # Use ssh-keyscan to get host key
      stdout, stderr, status = Open3.capture3('ssh-keyscan', '-H', hostname)

      unless status.success?
        warn "ssh-keyscan failed for #{hostname}: #{stderr}"
        return nil
      end

      # Parse the output - format is: "hostname algorithm key"
      # ssh-keyscan returns hashed hostnames with -H flag
      keys = stdout.lines.reject { |line| line.start_with?('#') }
      return nil if keys.empty?

      # Return first valid key
      keys.first&.strip
    rescue => e
      warn "Failed to get host key for #{hostname}: #{e.message}"
      nil
    end

    # List all known hosts
    def self.list_hosts
      return [] unless File.exist?(KNOWN_HOSTS_FILE)

      File.readlines(KNOWN_HOSTS_FILE, chomp: true)
        .reject { |line| line.strip.empty? || line.start_with?('#') }
        .map { |line| line.split.first }
        .compact
    end
  end

  # Manages binary checksum verification for security
  class ChecksumManager
    # Calculate SHA256 checksum of a local file
    # @param file_path [String] path to file
    # @return [String] hex digest of SHA256 checksum
    def self.calculate_local_checksum(file_path)
      Digest::SHA256.file(file_path).hexdigest
    rescue => e
      warn "Failed to calculate checksum for #{file_path}: #{e.message}"
      nil
    end

    # Verify checksum of a remote file via SSH
    # @param hostname [String] hostname to check
    # @param remote_path [String] path to file on remote host
    # @param expected_checksum [String] expected SHA256 checksum
    # @param ssh_user [String] SSH user for connection
    # @return [Boolean] true if checksums match
    def self.verify_remote_checksum(hostname, remote_path, expected_checksum, ssh_user: "deploy")
      # Get checksum from remote host
      stdout, stderr, status = Open3.capture3(
        'ssh',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=yes',
        "#{ssh_user}@#{hostname}",
        "sha256sum #{Shellwords.escape(remote_path)}"
      )

      unless status.success?
        warn "Failed to get remote checksum from #{hostname}: #{stderr}"
        return false
      end

      # Parse output: "checksum  filename"
      remote_checksum = stdout.strip.split.first
      remote_checksum == expected_checksum
    rescue => e
      warn "Checksum verification failed for #{hostname}: #{e.message}"
      false
    end

    # Display checksum information
    # @param file_path [String] path to file
    # @param label [String] label for display
    def self.display_checksum(file_path, label: "File")
      checksum = calculate_local_checksum(file_path)
      if checksum
        puts "#{label}: #{file_path}"
        puts "SHA256: #{checksum}"
      else
        puts "#{label}: #{file_path} (checksum calculation failed)"
      end
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

    def verify_checksum(expected_checksum)
      return true if @dry_run

      temp_file = "#{@temp_prefix}-#{@hostname}"
      ChecksumManager.verify_remote_checksum(
        @hostname,
        temp_file,
        expected_checksum,
        ssh_user: @ssh_user
      )
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
      # Add timeout wrapper and connection monitoring
      ssh_args = [
        'timeout', '300',  # 5 minute overall timeout
        'ssh',
        '-o', 'ConnectTimeout=5',
        '-o', 'ServerAliveInterval=5',    # Detect dead connections
        '-o', 'ServerAliveCountMax=3',     # 3 failed keepalives = disconnect
        '-o', 'StrictHostKeyChecking=yes', # Require known host key
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
    MAX_OUTPUT_SIZE = 1024 * 100  # 100KB max per output to prevent memory issues

    attr_reader :expected_checksum

    def initialize(hosts, options = {})
      @hosts = hosts
      @options = options
      @results = { success: [], failed: [] }
      @start_time = Time.now
      @expected_checksum = nil
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
      puts "Running preflight checks..."
      puts

      # Check 1: Verify source file exists
      print "  Checking source file..."
      unless File.exist?(SOURCE_FILE)
        puts " ✗ FAILED"
        puts "ERROR: Source file not found: #{SOURCE_FILE}"
        return false
      end

      if File.symlink?(SOURCE_FILE)
        puts " ✗ FAILED"
        puts "ERROR: Source file is a symlink: #{SOURCE_FILE}"
        return false
      end
      puts " ✓"

      # Check 2: Calculate source file checksum
      print "  Calculating checksum..."
      @expected_checksum = ChecksumManager.calculate_local_checksum(SOURCE_FILE)
      unless @expected_checksum
        puts " ✗ FAILED"
        puts "ERROR: Failed to calculate checksum for #{SOURCE_FILE}"
        return false
      end
      puts " ✓"
      puts "  SHA256: #{@expected_checksum}"

      # Check 3: Verify SSH host keys (unless --skip-host-verification)
      unless @options[:skip_host_verification]
        print "  Checking SSH host keys..."
        unknown_hosts = []

        @hosts.each do |hostname|
          unless KnownHostsManager.verify_host(hostname)
            unknown_hosts << hostname
          end
        end

        if unknown_hosts.any?
          puts " ✗ FAILED"
          puts
          puts "ERROR: The following hosts are not in known_hosts file:"
          unknown_hosts.each { |host| puts "  - #{host}" }
          puts
          puts "To add these hosts, run:"
          puts "  bin/update-orchestrators-ssh --add-hosts"
          puts
          puts "Or skip this check with:"
          puts "  bin/update-orchestrators-ssh --skip-host-verification"
          return false
        end
        puts " ✓"
      else
        puts "  ⚠ Skipping host key verification (--skip-host-verification)"
      end

      puts
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
      # Use parallel execution for better performance
      max_parallel = [@hosts.size, 10].min  # Max 10 concurrent updates

      puts
      puts "Deployment strategy: #{max_parallel} parallel workers"
      puts

      pool = Concurrent::FixedThreadPool.new(max_parallel, name: 'orchestrator-deploy')

      futures = @hosts.map do |hostname|
        Concurrent::Future.execute(executor: pool) do
          update_host_with_error_handling(hostname)
        end
      end

      # Wait for all updates with timeout (10 minutes per host max)
      futures.each_with_index do |future, index|
        begin
          future.value(600)  # 10 minute timeout per host
        rescue Concurrent::TimeoutError
          hostname = @hosts[index]
          puts "✗ #{hostname} timed out after 10 minutes"
          @results[:failed] << { host: hostname, reason: "Operation timed out" }
        end
      end
    ensure
      # Clean up thread pool
      pool&.shutdown
      pool&.wait_for_termination(30)
    end

    # Wrapper to handle exceptions during parallel execution
    def update_host_with_error_handling(hostname)
      update_host(hostname)
    rescue => e
      puts "✗ #{hostname} failed with exception: #{e.message}"
      @results[:failed] << { host: hostname, reason: "Exception: #{e.message}" }
    end

    def update_host(hostname)
      # Wrap entire operation in timeout (5 minutes per host)
      Timeout.timeout(300) do
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

        # Step 3: Verify checksum
        print "[#{timestamp}] Verifying checksum..."
        unless executor.verify_checksum(@expected_checksum)
          puts " ✗ FAILED"
          @results[:failed] << { host: hostname, reason: "Checksum verification failed" }
          return
        end
        puts " ✓"

        # Step 4: Execute update
        print "[#{timestamp}] Executing update commands..."
        result = executor.update_orchestrator
        unless result[:success]
          puts " ✗ FAILED"
          puts
          # Truncate output to prevent memory issues
          output = truncate_output(result[:output], MAX_OUTPUT_SIZE)
          error = truncate_output(result[:error], MAX_OUTPUT_SIZE)
          puts "Output: #{output}" unless output.empty?
          puts "Error: #{error}" unless error.empty?
          @results[:failed] << { host: hostname, reason: "Update commands failed" }
          return
        end
        puts " ✓"

        # Print update output (truncated)
        output = truncate_output(result[:output], MAX_OUTPUT_SIZE)
        puts output unless output.empty?

        # Step 5: Verify service
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
    rescue Timeout::Error
      puts " ✗ TIMEOUT"
      @results[:failed] << { host: hostname, reason: "Operation timed out after 5 minutes" }
    end

    # Truncate output to prevent memory issues
    def truncate_output(output, max_size)
      return "" if output.nil? || output.empty?
      return output if output.bytesize <= max_size

      output[0...max_size] + "\n[Output truncated - exceeded #{max_size} bytes]"
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

      # Handle --show-checksum
      if options[:show_checksum]
        source_file = "host-daemon/xmrig-orchestrator"
        unless File.exist?(source_file)
          puts "ERROR: Source file not found: #{source_file}"
          exit 1
        end

        puts
        ChecksumManager.display_checksum(source_file, label: "Orchestrator binary")
        puts
        puts "This checksum will be verified on each host after deployment."
        exit 0
      end

      # Handle --list-hosts
      if options[:list_hosts]
        puts "Known hosts:"
        known = KnownHostsManager.list_hosts
        if known.empty?
          puts "  (none)"
        else
          known.each { |host| puts "  - #{host}" }
        end
        exit 0
      end

      hosts = determine_hosts(options)

      # Handle --add-hosts
      if options[:add_hosts]
        puts "Adding hosts to known_hosts file..."
        puts
        hosts.each do |hostname|
          print "  #{hostname}..."
          if KnownHostsManager.add_host(hostname)
            puts " ✓"
          else
            puts " ✗ FAILED"
          end
        end
        puts
        puts "Done. Run without --add-hosts to deploy."
        exit 0
      end

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
        verbose: false,
        add_hosts: false,
        skip_host_verification: false,
        list_hosts: false,
        show_checksum: false
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

        opts.on("--add-hosts", "Add all hosts to known_hosts file") do
          options[:add_hosts] = true
        end

        opts.on("--list-hosts", "List all known hosts") do
          options[:list_hosts] = true
        end

        opts.on("--show-checksum", "Display orchestrator binary checksum") do
          options[:show_checksum] = true
        end

        opts.on("--skip-host-verification", "Skip SSH host key verification (INSECURE)") do
          options[:skip_host_verification] = true
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
