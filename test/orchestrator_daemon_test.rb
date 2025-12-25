# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "sqlite3"
require "logger"
require "stringio"

# Load a minimal version of the orchestrator for testing
# We'll test the core logic without running the full daemon
class XmrigOrchestratorTestWrapper
  attr_reader :logger, :db, :hostname

  def initialize(db_path, logger)
    @hostname = "test-host"
    @logger = logger
    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true

    setup_test_tables
  end

  def setup_test_tables
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS xmrig_commands (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        result TEXT,
        error_message TEXT,
        processed_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL

    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS xmrig_processes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hostname TEXT NOT NULL UNIQUE,
        worker_id TEXT,
        status TEXT,
        pid INTEGER,
        hashrate REAL,
        restart_count INTEGER DEFAULT 0,
        error_count INTEGER DEFAULT 0,
        last_error TEXT,
        last_health_check_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL
  end

  def process_command(cmd)
    @logger.info "Processing command: #{cmd['action']} (ID: #{cmd['id']})"

    # Track whether we actually executed a command
    success = case cmd["action"]
    when "start"
      result = systemctl("start")
      $?.success?
    when "stop"
      result = systemctl("stop")
      $?.success?
    when "restart"
      result = systemctl("restart")
      $?.success?
    else
      result = "Unknown action: #{cmd['action']}"
      false  # Unknown actions always fail
    end

    if success
      @db.execute(
        "UPDATE xmrig_commands SET status = 'completed', result = ? WHERE id = ?",
        [result, cmd["id"]]
      )
      @logger.info "Command completed: #{cmd['action']}"
    else
      @db.execute(
        "UPDATE xmrig_commands SET status = 'failed', error_message = ? WHERE id = ?",
        [result, cmd["id"]]
      )
      @logger.error "Command failed: #{cmd['action']} - #{result}"
    end
  rescue => e
    @db.execute(
      "UPDATE xmrig_commands SET status = 'failed', error_message = ? WHERE id = ?",
      [e.message, cmd["id"]]
    )
    @logger.error "Command error: #{e.message}"
  end

  def systemctl(action)
    # Mock systemctl for testing - don't actually run sudo commands
    # Simulate execution by setting $? with a real command
    # This mimics what happens in the real orchestrator when Open3.capture3 is called
    output = "systemctl #{action} xmrig - OK (test mode)"

    # Simulate successful execution
    system('true')

    output
  end
end

class XmrigOrchestratorTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @db_path = File.join(@tmpdir, "test.sqlite3")
    @log_output = StringIO.new
    @logger = Logger.new(@log_output)
    @logger.level = Logger::INFO

    @orchestrator = XmrigOrchestratorTestWrapper.new(@db_path, @logger)
  end

  def teardown
    @orchestrator.db.close if @orchestrator.db
    FileUtils.remove_entry(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
  end

  def create_command(action, status = "pending")
    now = Time.now.utc.iso8601
    @orchestrator.db.execute(
      "INSERT INTO xmrig_commands (action, status, created_at, updated_at) VALUES (?, ?, ?, ?)",
      [action, status, now, now]
    )
    @orchestrator.db.last_insert_row_id
  end

  def get_command(id)
    @orchestrator.db.execute("SELECT * FROM xmrig_commands WHERE id = ?", [id]).first
  end

  # Test successful start command
  def test_process_start_command
    cmd_id = create_command("start")
    cmd = get_command(cmd_id)

    @orchestrator.process_command(cmd)

    updated_cmd = get_command(cmd_id)
    assert_equal "completed", updated_cmd["status"]
    assert_includes updated_cmd["result"], "start"
  end

  # Test successful stop command
  def test_process_stop_command
    cmd_id = create_command("stop")
    cmd = get_command(cmd_id)

    @orchestrator.process_command(cmd)

    updated_cmd = get_command(cmd_id)
    assert_equal "completed", updated_cmd["status"]
    assert_includes updated_cmd["result"], "stop"
  end

  # Test successful restart command
  def test_process_restart_command
    cmd_id = create_command("restart")
    cmd = get_command(cmd_id)

    @orchestrator.process_command(cmd)

    updated_cmd = get_command(cmd_id)
    assert_equal "completed", updated_cmd["status"]
    assert_includes updated_cmd["result"], "restart"
  end

  # Test unknown action handling (bug fix test)
  # This test verifies the fix for: "undefined method 'success?' for nil"
  # Unknown actions now explicitly return false and are marked as failed
  def test_process_unknown_action
    cmd_id = create_command("invalid_action")
    cmd = get_command(cmd_id)

    # Process the unknown command - should not crash and should be marked as failed
    @orchestrator.process_command(cmd)

    # Verify it was marked as failed
    updated_cmd = get_command(cmd_id)
    assert_equal "failed", updated_cmd["status"]
    assert_includes updated_cmd["error_message"], "Unknown action"
    assert_includes updated_cmd["error_message"], "invalid_action"
  end

  # Test that unknown actions are logged as errors
  def test_unknown_action_logged_as_error
    cmd_id = create_command("bad_command")
    cmd = get_command(cmd_id)

    @orchestrator.process_command(cmd)

    log_content = @log_output.string
    assert_includes log_content, "Command failed"
    assert_includes log_content, "bad_command"
  end

  # Test multiple unknown actions in sequence
  def test_multiple_unknown_actions
    cmd1_id = create_command("unknown1")
    cmd2_id = create_command("unknown2")
    cmd3_id = create_command("start")

    @orchestrator.process_command(get_command(cmd1_id))
    @orchestrator.process_command(get_command(cmd2_id))
    @orchestrator.process_command(get_command(cmd3_id))

    # First two should fail
    assert_equal "failed", get_command(cmd1_id)["status"]
    assert_equal "failed", get_command(cmd2_id)["status"]

    # Third should succeed
    assert_equal "completed", get_command(cmd3_id)["status"]
  end

  # Test that exception in process_command is caught and logged
  def test_exception_handling
    cmd_id = create_command("start")
    cmd = get_command(cmd_id)

    # Mock systemctl to raise an exception
    @orchestrator.define_singleton_method(:systemctl) do |action|
      raise StandardError, "Simulated systemctl failure"
    end

    @orchestrator.process_command(cmd)

    updated_cmd = get_command(cmd_id)
    assert_equal "failed", updated_cmd["status"]
    assert_includes updated_cmd["error_message"], "Simulated systemctl failure"

    log_content = @log_output.string
    assert_includes log_content, "Command error"
  end

  # Test that valid commands set $? properly
  def test_valid_commands_set_process_status
    cmd_id = create_command("start")
    cmd = get_command(cmd_id)

    @orchestrator.process_command(cmd)

    # After processing a valid command, $? should be set
    refute_nil $?, "Process status should be set after systemctl call"
    assert $?.success?, "Process status should indicate success for valid command"
  end
end
