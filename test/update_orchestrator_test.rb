# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "yaml"
require "stringio"

# Load the module we're testing
require_relative "../lib/orchestrator_updater"

class ConfigTest < Minitest::Test
  # Disable parallel execution for this test class to make stubbing work
  parallelize(workers: 1) if respond_to?(:parallelize)

  def setup
    @valid_config = {
      "servers" => {
        "web" => {
          "hosts" => ["mini-1", "miner-beta", "miner-gamma", "miner-delta"]
        }
      }
    }
  end

  def test_load_hosts_from_valid_config
    # Create temporary config file with valid configuration
    temp_file = "/tmp/valid_config_#{Process.pid}.yml"
    File.write(temp_file, @valid_config.to_yaml)

    original_path = OrchestratorUpdater::Config::CONFIG_PATH
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, temp_file)

    hosts = OrchestratorUpdater::Config.load_hosts
    assert_equal ["mini-1", "miner-beta", "miner-gamma", "miner-delta"], hosts
  ensure
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, original_path) if original_path
    File.unlink(temp_file) if temp_file && File.exist?(temp_file)
  end

  def test_load_hosts_missing_config
    # Temporarily change CONFIG_PATH to point to non-existent file
    original_path = OrchestratorUpdater::Config::CONFIG_PATH
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, "/tmp/nonexistent_config_#{Process.pid}.yml")

    error = assert_raises(OrchestratorUpdater::ConfigError) do
      OrchestratorUpdater::Config.load_hosts
    end
    assert_match(/config.*not found/i, error.message)
  ensure
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, original_path) if original_path
  end

  def test_load_hosts_empty_config
    # Create temporary config file with empty hosts
    temp_file = "/tmp/empty_config_#{Process.pid}.yml"
    File.write(temp_file, { "servers" => { "web" => { "hosts" => [] } } }.to_yaml)

    original_path = OrchestratorUpdater::Config::CONFIG_PATH
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, temp_file)

    error = assert_raises(OrchestratorUpdater::ConfigError) do
      OrchestratorUpdater::Config.load_hosts
    end
    assert_match(/no hosts/i, error.message)
  ensure
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, original_path) if original_path
    File.unlink(temp_file) if temp_file && File.exist?(temp_file)
  end

  def test_load_hosts_invalid_yaml
    # Create temporary file with invalid YAML
    temp_file = "/tmp/invalid_yaml_#{Process.pid}.yml"
    File.write(temp_file, "invalid: yaml: content: [unclosed")

    original_path = OrchestratorUpdater::Config::CONFIG_PATH
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, temp_file)

    error = assert_raises(OrchestratorUpdater::ConfigError) do
      OrchestratorUpdater::Config.load_hosts
    end
    assert_match(/invalid.*yaml/i, error.message)
  ensure
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, original_path) if original_path
    File.unlink(temp_file) if temp_file && File.exist?(temp_file)
  end

  def test_load_hosts_missing_servers_key
    # Create temporary config file without servers key
    temp_file = "/tmp/no_servers_#{Process.pid}.yml"
    File.write(temp_file, { "other" => "data" }.to_yaml)

    original_path = OrchestratorUpdater::Config::CONFIG_PATH
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, temp_file)

    error = assert_raises(OrchestratorUpdater::ConfigError) do
      OrchestratorUpdater::Config.load_hosts
    end
    assert_match(/no hosts/i, error.message)
  ensure
    OrchestratorUpdater::Config.const_set(:CONFIG_PATH, original_path) if original_path
    File.unlink(temp_file) if temp_file && File.exist?(temp_file)
  end
end

class HostValidatorTest < Minitest::Test
  def test_valid_hostnames
    assert OrchestratorUpdater::HostValidator.valid?("mini-1")
    assert OrchestratorUpdater::HostValidator.valid?("miner-beta")
    assert OrchestratorUpdater::HostValidator.valid?("host.example.com")
    assert OrchestratorUpdater::HostValidator.valid?("server123")
    assert OrchestratorUpdater::HostValidator.valid?("web-01.prod.example.com")
  end

  def test_invalid_hostnames_injection
    refute OrchestratorUpdater::HostValidator.valid?("mini-1; rm -rf /")
    refute OrchestratorUpdater::HostValidator.valid?("mini-1 && evil")
    refute OrchestratorUpdater::HostValidator.valid?("mini-1`whoami`")
    refute OrchestratorUpdater::HostValidator.valid?("mini-1$(whoami)")
    refute OrchestratorUpdater::HostValidator.valid?("mini-1|cat /etc/passwd")
  end

  def test_invalid_hostnames_path_traversal
    refute OrchestratorUpdater::HostValidator.valid?("../../../etc/passwd")
    refute OrchestratorUpdater::HostValidator.valid?("host/../evil")
    refute OrchestratorUpdater::HostValidator.valid?("../host")
  end

  def test_invalid_hostnames_special_chars
    refute OrchestratorUpdater::HostValidator.valid?("mini 1")  # space
    refute OrchestratorUpdater::HostValidator.valid?("mini'1")  # single quote
    refute OrchestratorUpdater::HostValidator.valid?("mini\"1") # double quote
    refute OrchestratorUpdater::HostValidator.valid?("mini@1")  # @ symbol
    refute OrchestratorUpdater::HostValidator.valid?("mini#1")  # hash
    refute OrchestratorUpdater::HostValidator.valid?("mini$1")  # dollar sign
  end

  def test_invalid_hostnames_length
    # Test maximum total length (253 chars DNS limit)
    # But each label must be max 63 chars
    long_hostname = "a" * 254
    refute OrchestratorUpdater::HostValidator.valid?(long_hostname)

    # Single label of 64+ chars should be invalid (exceeds 63 char label limit)
    long_label = "a" * 64
    refute OrchestratorUpdater::HostValidator.valid?(long_label)

    # Valid: max 63 char labels, total exactly 253
    # (63 + ".") * 3 + 61 = 64*3 + 61 = 192 + 61 = 253
    max_hostname = ("a" * 63 + ".") * 3 + "a" * 61  # 253 chars total
    assert OrchestratorUpdater::HostValidator.valid?(max_hostname)

    # Valid: exactly 63 char label
    max_label = "a" * 63
    assert OrchestratorUpdater::HostValidator.valid?(max_label)
  end

  def test_invalid_hostnames_empty
    refute OrchestratorUpdater::HostValidator.valid?("")
    refute OrchestratorUpdater::HostValidator.valid?(nil)
  end

  def test_invalid_hostnames_starting_with_invalid_chars
    refute OrchestratorUpdater::HostValidator.valid?("-host")  # starts with dash
    refute OrchestratorUpdater::HostValidator.valid?(".host")  # starts with dot
  end
end

class SSHExecutorTest < Minitest::Test
  def setup
    @executor = OrchestratorUpdater::SSHExecutor.new("test-host")
  end

  def double_success_status
    status = Object.new
    status.define_singleton_method(:success?) { true }
    status.define_singleton_method(:exitstatus) { 0 }
    status
  end

  def double_failure_status
    status = Object.new
    status.define_singleton_method(:success?) { false }
    status.define_singleton_method(:exitstatus) { 1 }
    status
  end

  def test_check_connectivity_success
    stdout, stderr, status = "ok\n", "", double_success_status

    Open3.stub :capture3, [stdout, stderr, status] do
      assert @executor.check_connectivity
    end
  end

  def test_check_connectivity_timeout
    stdout, stderr, status = "", "Connection timed out", double_failure_status

    Open3.stub :capture3, [stdout, stderr, status] do
      refute @executor.check_connectivity
    end
  end

  def test_check_connectivity_auth_failure
    stdout, stderr, status = "", "Permission denied", double_failure_status

    Open3.stub :capture3, [stdout, stderr, status] do
      refute @executor.check_connectivity
    end
  end

  def test_copy_orchestrator_success
    stdout, stderr, status = "", "", double_success_status

    Open3.stub :capture3, [stdout, stderr, status] do
      assert @executor.copy_orchestrator("host-daemon/xmrig-orchestrator")
    end
  end

  def test_copy_orchestrator_failure
    stdout, stderr, status = "", "scp: connection failed", double_failure_status

    Open3.stub :capture3, [stdout, stderr, status] do
      refute @executor.copy_orchestrator("host-daemon/xmrig-orchestrator")
    end
  end

  def test_update_orchestrator_success
    stdout = "  ✓ XMRig detected\n  ✓ Orchestrator updated\n  ✓ Service verified"
    stderr = ""
    status = double_success_status

    Open3.stub :capture3, [stdout, stderr, status] do
      result = @executor.update_orchestrator
      assert result[:success]
      assert_match(/verified/i, result[:output])
    end
  end

  def test_update_orchestrator_service_restart_failure
    stdout = "  ✓ Orchestrator updated"
    stderr = "Failed to restart xmrig-orchestrator.service"
    status = double_failure_status

    Open3.stub :capture3, [stdout, stderr, status] do
      result = @executor.update_orchestrator
      refute result[:success]
      assert_match(/failed/i, result[:error])
    end
  end

  def test_verify_service_running
    stdout, stderr, status = "active\n", "", double_success_status

    Open3.stub :capture3, [stdout, stderr, status] do
      assert @executor.verify_service
    end
  end

  def test_verify_service_not_running
    stdout, stderr, status = "inactive\n", "", double_failure_status

    Open3.stub :capture3, [stdout, stderr, status] do
      refute @executor.verify_service
    end
  end

  def test_ssh_command_quoting
    # Verify that SSH commands use array form (not string interpolation)
    # This test ensures we're using Open3.capture3 with array arguments
    executor = OrchestratorUpdater::SSHExecutor.new("test-host")

    # Mock Open3.capture3 and capture the arguments that were passed
    executed_args = nil
    Open3.stub :capture3, lambda { |*args|
      executed_args = args
      ["ok", "", double_success_status]
    } do
      executor.check_connectivity
    end

    # Should pass array of arguments (safe from injection)
    assert_kind_of Array, executed_args
    assert_equal "ssh", executed_args[0]      # SSH command is first

    # Should contain SSH options
    assert executed_args.include?("ConnectTimeout=5")

    # Should contain user@host
    assert executed_args.any? { |arg| arg.include?("deploy@test-host") }

    # Should contain the actual command
    assert executed_args.include?("echo ok")
  end

  def test_dry_run_mode
    # Verify dry run doesn't execute commands
    executor = OrchestratorUpdater::SSHExecutor.new("test-host", dry_run: true)

    # Open3.capture3 should NOT be called
    Open3.stub :capture3, -> { raise "Should not execute in dry-run mode" } do
      # These should not raise because they shouldn't call Open3.capture3
      assert executor.check_connectivity
      assert executor.copy_orchestrator("host-daemon/xmrig-orchestrator")
      result = executor.update_orchestrator
      assert result[:success]
      assert_match(/dry.run/i, result[:output])
    end
  end

  def test_verbose_mode
    # Verbose mode should still execute but log commands
    executor = OrchestratorUpdater::SSHExecutor.new("test-host", verbose: true)

    # Capture stdout to verify verbose logging
    stdout_capture = StringIO.new
    $stdout = stdout_capture

    Open3.stub :capture3, ["ok", "", double_success_status] do
      executor.check_connectivity
    end

    $stdout = STDOUT
    output = stdout_capture.string

    # Should log the SSH command
    assert_match(/ssh.*test-host/i, output)
  end
end

class UpdateCoordinatorTest < Minitest::Test
  def setup
    @hosts = ["mini-1", "miner-beta"]
    @options = { yes: true, dry_run: false, verbose: false }
  end

  def test_run_all_hosts_success
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # Mock SSHExecutor to always succeed
    mock_executor = Minitest::Mock.new
    mock_executor.expect :check_connectivity, true
    mock_executor.expect :copy_orchestrator, true, [String]
    mock_executor.expect :update_orchestrator, { success: true, output: "OK", error: "" }
    mock_executor.expect :verify_service, true
    mock_executor.expect :check_connectivity, true
    mock_executor.expect :copy_orchestrator, true, [String]
    mock_executor.expect :update_orchestrator, { success: true, output: "OK", error: "" }
    mock_executor.expect :verify_service, true

    OrchestratorUpdater::SSHExecutor.stub :new, mock_executor do
      exit_code = coordinator.run
      assert_equal 0, exit_code
    end
  end

  def test_run_partial_failure
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # First host succeeds, second fails
    call_count = 0
    OrchestratorUpdater::SSHExecutor.stub :new, lambda { |hostname, **_opts|
      call_count += 1
      if call_count == 1
        # First host succeeds
        mock = Minitest::Mock.new
        mock.expect :check_connectivity, true
        mock.expect :copy_orchestrator, true, [String]
        mock.expect :update_orchestrator, { success: true, output: "OK", error: "" }
        mock.expect :verify_service, true
        mock
      else
        # Second host fails on connectivity
        mock = Minitest::Mock.new
        mock.expect :check_connectivity, false
        mock
      end
    } do
      exit_code = coordinator.run
      assert_equal 1, exit_code  # Should return 1 for any failure
    end
  end

  def test_run_all_hosts_failure
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # Mock SSHExecutor to always fail
    mock_executor = Minitest::Mock.new
    mock_executor.expect :check_connectivity, false
    mock_executor.expect :check_connectivity, false

    OrchestratorUpdater::SSHExecutor.stub :new, mock_executor do
      exit_code = coordinator.run
      assert_equal 1, exit_code
    end
  end

  def test_run_continues_after_host_failure
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # Track which hosts were attempted
    attempted_hosts = []

    OrchestratorUpdater::SSHExecutor.stub :new, lambda { |hostname, **_opts|
      attempted_hosts << hostname
      mock = Minitest::Mock.new
      mock.expect :check_connectivity, false  # All fail
      mock
    } do
      coordinator.run

      # Verify all hosts were attempted despite first failure
      assert_equal @hosts.sort, attempted_hosts.sort
    end
  end

  def test_display_summary_captures_output
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # Capture stdout
    stdout_capture = StringIO.new
    $stdout = stdout_capture

    # Mock all hosts succeed
    mock_executor = Minitest::Mock.new
    mock_executor.expect :check_connectivity, true
    mock_executor.expect :copy_orchestrator, true, [String]
    mock_executor.expect :update_orchestrator, { success: true, output: "OK", error: "" }
    mock_executor.expect :verify_service, true
    mock_executor.expect :check_connectivity, true
    mock_executor.expect :copy_orchestrator, true, [String]
    mock_executor.expect :update_orchestrator, { success: true, output: "OK", error: "" }
    mock_executor.expect :verify_service, true

    OrchestratorUpdater::SSHExecutor.stub :new, mock_executor do
      coordinator.run
    end

    $stdout = STDOUT
    output = stdout_capture.string

    # Verify summary output
    assert_match(/success.*2/i, output)
    assert_match(/mini-1/, output)
    assert_match(/miner-beta/, output)
  end

  def test_display_summary_with_failures
    coordinator = OrchestratorUpdater::UpdateCoordinator.new(@hosts, @options)

    # Capture stdout
    stdout_capture = StringIO.new
    $stdout = stdout_capture

    # Mock all hosts fail
    mock_executor = Minitest::Mock.new
    mock_executor.expect :check_connectivity, false
    mock_executor.expect :check_connectivity, false

    OrchestratorUpdater::SSHExecutor.stub :new, mock_executor do
      coordinator.run
    end

    $stdout = STDOUT
    output = stdout_capture.string

    # Verify failure output
    assert_match(/failed/i, output)
    assert_match(/retry/i, output)
  end
end

class CLITest < Minitest::Test
  def test_parse_options_defaults
    options = OrchestratorUpdater::CLI.send(:parse_options, [])
    assert_equal false, options[:yes]
    assert_equal false, options[:dry_run]
    assert_equal false, options[:verbose]
    assert_nil options[:host]
  end

  def test_parse_options_host
    options = OrchestratorUpdater::CLI.send(:parse_options, ["--host", "mini-1"])
    assert_equal "mini-1", options[:host]
  end

  def test_parse_options_yes
    options = OrchestratorUpdater::CLI.send(:parse_options, ["--yes"])
    assert options[:yes]
  end

  def test_parse_options_dry_run
    options = OrchestratorUpdater::CLI.send(:parse_options, ["--dry-run"])
    assert options[:dry_run]
  end

  def test_parse_options_verbose
    options = OrchestratorUpdater::CLI.send(:parse_options, ["--verbose"])
    assert options[:verbose]
  end

  def test_parse_options_combined
    options = OrchestratorUpdater::CLI.send(:parse_options, ["--host", "mini-1", "--yes", "--verbose"])
    assert_equal "mini-1", options[:host]
    assert options[:yes]
    assert options[:verbose]
  end

  def test_determine_hosts_from_config
    # Mock Config.load_hosts
    OrchestratorUpdater::Config.stub :load_hosts, ["mini-1", "miner-beta"] do
      hosts = OrchestratorUpdater::CLI.send(:determine_hosts, {})
      assert_equal ["mini-1", "miner-beta"], hosts
    end
  end

  def test_determine_hosts_from_option
    # When --host is specified, should use that instead of config
    hosts = OrchestratorUpdater::CLI.send(:determine_hosts, { host: "mini-1" })
    assert_equal ["mini-1"], hosts
  end

  def test_determine_hosts_validates_hostnames
    # Should reject invalid hostname
    error = assert_raises(OrchestratorUpdater::HostnameError) do
      OrchestratorUpdater::CLI.send(:determine_hosts, { host: "mini-1; rm -rf /" })
    end
    assert_match(/invalid/i, error.message)
  end

  def test_run_integration
    # Integration test: full CLI flow
    # Mock all dependencies
    OrchestratorUpdater::Config.stub :load_hosts, ["mini-1"] do
      mock_coordinator = Minitest::Mock.new
      mock_coordinator.expect :run, 0

      OrchestratorUpdater::UpdateCoordinator.stub :new, mock_coordinator do
        # Capture exit call
        exit_called = false
        exit_code = nil

        # Stub File.exist? to return true for source file check
        File.stub :exist?, true do
          Kernel.stub :exit, lambda { |code|
            exit_called = true
            exit_code = code
            # Don't actually exit - just record the call
          } do
            OrchestratorUpdater::CLI.run(["--yes"])
          end
        end

        assert exit_called
        assert_equal 0, exit_code
      end
    end
  end
end
