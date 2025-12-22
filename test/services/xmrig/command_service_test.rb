require "test_helper"

class Xmrig::CommandServiceTest < ActiveSupport::TestCase
  setup do
    @service = Xmrig::CommandService
  end

  # Purpose: Validates start command creation
  # Can fail if: Command not created or wrong attributes
  test "start_mining creates pending start command" do
    assert_difference "XmrigCommand.count", 1 do
      @service.start_mining("test-host", reason: "test")
    end

    cmd = XmrigCommand.last
    assert_equal "test-host", cmd.hostname
    assert_equal "start", cmd.action
    assert_equal "pending", cmd.status
    assert_equal "test", cmd.reason
  end

  # Purpose: Validates stop command creation
  # Can fail if: Command not created or wrong attributes
  test "stop_mining creates pending stop command" do
    assert_difference "XmrigCommand.count", 1 do
      @service.stop_mining("test-host", reason: "maintenance")
    end

    cmd = XmrigCommand.last
    assert_equal "test-host", cmd.hostname
    assert_equal "stop", cmd.action
    assert_equal "pending", cmd.status
    assert_equal "maintenance", cmd.reason
  end

  # Purpose: Validates restart command creation
  # Can fail if: Command not created or wrong attributes
  test "restart_mining creates pending restart command" do
    assert_difference "XmrigCommand.count", 1 do
      @service.restart_mining("test-host", reason: "health_check_failed")
    end

    cmd = XmrigCommand.last
    assert_equal "test-host", cmd.hostname
    assert_equal "restart", cmd.action
    assert_equal "pending", cmd.status
    assert_equal "health_check_failed", cmd.reason
  end

  # Purpose: Validates command superseding logic
  # Can fail if: Old commands not canceled
  test "start_mining cancels pending commands" do
    old_cmd = XmrigCommand.create!(hostname: "host1", action: "stop", status: "pending")

    @service.start_mining("host1")

    old_cmd.reload
    assert_equal "failed", old_cmd.status
    assert_includes old_cmd.error_message, "Superseded"
  end

  # Purpose: Validates only pending commands are canceled
  # Can fail if: Non-pending commands affected
  test "start_mining only cancels pending commands" do
    processing_cmd = XmrigCommand.create!(hostname: "host1", action: "stop", status: "processing")
    completed_cmd = XmrigCommand.create!(hostname: "host1", action: "restart", status: "completed")

    @service.start_mining("host1")

    processing_cmd.reload
    completed_cmd.reload

    assert_equal "processing", processing_cmd.status
    assert_equal "completed", completed_cmd.status
  end

  # Purpose: Validates default reason for start_mining
  # Can fail if: Default reason not applied
  test "start_mining uses default reason when not provided" do
    @service.start_mining("test-host")

    cmd = XmrigCommand.last
    assert_equal "manual", cmd.reason
  end

  # Purpose: Validates commands for different hosts don't interfere
  # Can fail if: Cancellation affects wrong host
  test "commands for different hosts are independent" do
    host1_cmd = XmrigCommand.create!(hostname: "host1", action: "start", status: "pending")
    host2_cmd = XmrigCommand.create!(hostname: "host2", action: "start", status: "pending")

    @service.stop_mining("host1")

    host1_cmd.reload
    host2_cmd.reload

    assert_equal "failed", host1_cmd.status
    assert_equal "pending", host2_cmd.status
  end
end
