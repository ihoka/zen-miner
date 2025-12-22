require "test_helper"

class XmrigCommandTest < ActiveSupport::TestCase
  # Purpose: Validates pending scope orders by creation time
  # Can fail if: Ordering broken or wrong records returned
  test "pending scope returns oldest first" do
    cmd2 = XmrigCommand.create!(action: "stop", status: "pending")
    cmd1 = XmrigCommand.create!(action: "start", status: "pending")
    # Force different created_at by manually updating
    cmd1.update_column(:created_at, 2.minutes.ago)

    pending = XmrigCommand.pending.to_a

    assert_equal cmd1.id, pending.first.id
    assert_equal cmd2.id, pending.last.id
  end

  # Purpose: Validates pending scope excludes non-pending commands
  # Can fail if: Scope filter broken
  test "pending scope only returns pending commands" do
    pending_cmd = XmrigCommand.create!(action: "start", status: "pending")
    completed_cmd = XmrigCommand.create!(action: "start", status: "completed")
    failed_cmd = XmrigCommand.create!(action: "start", status: "failed")

    pending_cmds = XmrigCommand.pending

    assert_includes pending_cmds, pending_cmd
    assert_not_includes pending_cmds, completed_cmd
    assert_not_includes pending_cmds, failed_cmd
  end

  # Purpose: Validates command status transitions
  # Can fail if: Status updates don't persist
  test "mark_processing! updates status and timestamp" do
    cmd = XmrigCommand.create!(action: "start", status: "pending")
    cmd.mark_processing!

    assert_equal "processing", cmd.status
    assert_not_nil cmd.processed_at
  end

  # Purpose: Validates completion with result
  # Can fail if: Result not persisted
  test "mark_completed! updates status and stores result" do
    cmd = XmrigCommand.create!(action: "start", status: "pending")
    cmd.mark_completed!("Started successfully")

    assert_equal "completed", cmd.status
    assert_equal "Started successfully", cmd.result
  end

  # Purpose: Validates failure tracking
  # Can fail if: Error message not persisted
  test "mark_failed! stores error message" do
    cmd = XmrigCommand.create!(action: "start", status: "pending")
    cmd.mark_failed!("Connection timeout")

    assert_equal "failed", cmd.status
    assert_equal "Connection timeout", cmd.error_message
  end

  # Purpose: Validates recent scope filters by time
  # Can fail if: Time comparison broken
  test "recent scope returns commands from last hour" do
    recent_cmd = XmrigCommand.create!(action: "start", status: "pending")
    old_cmd = XmrigCommand.create!(action: "start", status: "pending")
    old_cmd.update_column(:created_at, 2.hours.ago)

    recent_commands = XmrigCommand.recent

    assert_includes recent_commands, recent_cmd
    assert_not_includes recent_commands, old_cmd
  end

  # Purpose: Validates action inclusion validation
  # Can fail if: Action validation not enforced
  test "validates action is in allowed values" do
    cmd = XmrigCommand.new(action: "invalid_action", status: "pending")

    assert_not cmd.valid?
    assert_includes cmd.errors[:action], "is not included in the list"
  end

  # Purpose: Validates status inclusion validation
  # Can fail if: Status validation not enforced
  test "validates status is in allowed values" do
    cmd = XmrigCommand.new(action: "start", status: "invalid_status")

    assert_not cmd.valid?
    assert_includes cmd.errors[:status], "is not included in the list"
  end

  # Purpose: Validates required fields
  # Can fail if: Presence validations not enforced
  test "validates presence of required fields" do
    cmd = XmrigCommand.new

    assert_not cmd.valid?
    assert_includes cmd.errors[:action], "can't be blank"
    # Status has a default value, so it won't fail presence validation
  end

  # Purpose: Validates default status is pending
  # Can fail if: Default value not set in database
  test "defaults status to pending" do
    cmd = XmrigCommand.new(action: "start")

    assert_equal "pending", cmd.status
  end
end
