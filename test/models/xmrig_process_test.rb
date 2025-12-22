require "test_helper"

class XmrigProcessTest < ActiveSupport::TestCase
  # Purpose: Validates hostname uniqueness constraint
  # Can fail if: Database constraint not enforced
  test "enforces unique hostname" do
    XmrigProcess.create!(hostname: "test-host", worker_id: "test", status: "running")

    assert_raises(ActiveRecord::RecordInvalid) do
      XmrigProcess.create!(hostname: "test-host", worker_id: "test2", status: "running")
    end
  end

  # Purpose: Validates health check staleness detection
  # Can fail if: Time comparison logic broken
  test "stale? returns true for old health checks" do
    process = XmrigProcess.create!(
      hostname: "test-host",
      worker_id: "test",
      status: "running",
      last_health_check_at: 10.minutes.ago
    )

    assert process.stale?
  end

  # Purpose: Validates healthy process detection
  # Can fail if: Status or timestamp checks broken
  test "healthy? returns true for recent running process" do
    process = XmrigProcess.create!(
      hostname: "test-host",
      worker_id: "test",
      status: "running",
      last_health_check_at: 1.minute.ago
    )

    assert process.healthy?
  end

  # Purpose: Validates healthy? returns false for non-running process
  # Can fail if: Status check doesn't properly validate "running" status
  test "healthy? returns false for non-running process" do
    process = XmrigProcess.create!(
      hostname: "test-host",
      worker_id: "test",
      status: "stopped",
      last_health_check_at: 1.minute.ago
    )

    assert_not process.healthy?
  end

  # Purpose: Validates healthy? returns false for stale process
  # Can fail if: Timestamp check broken
  test "healthy? returns false for stale process" do
    process = XmrigProcess.create!(
      hostname: "test-host",
      worker_id: "test",
      status: "running",
      last_health_check_at: 10.minutes.ago
    )

    assert_not process.healthy?
  end

  # Purpose: Validates for_host finder with existing record
  # Can fail if: find_or_initialize_by broken
  test "for_host returns existing process" do
    existing = XmrigProcess.create!(
      hostname: "test-host",
      worker_id: "test",
      status: "running"
    )

    process = XmrigProcess.for_host("test-host")

    assert_equal existing.id, process.id
    assert process.persisted?
  end

  # Purpose: Validates for_host creates new record with defaults
  # Can fail if: Initialization block doesn't execute
  test "for_host initializes new process with defaults" do
    process = XmrigProcess.for_host("new-host")

    assert process.new_record?
    assert_equal "new-host", process.hostname
    assert_equal "new-host-production", process.worker_id
    assert_equal "stopped", process.status
  end

  # Purpose: Validates active scope includes correct statuses
  # Can fail if: Scope definition broken
  test "active scope includes starting, running, and unhealthy processes" do
    starting = XmrigProcess.create!(hostname: "host1", worker_id: "w1", status: "starting")
    running = XmrigProcess.create!(hostname: "host2", worker_id: "w2", status: "running")
    unhealthy = XmrigProcess.create!(hostname: "host3", worker_id: "w3", status: "unhealthy")
    stopped = XmrigProcess.create!(hostname: "host4", worker_id: "w4", status: "stopped")

    active_processes = XmrigProcess.active

    assert_includes active_processes, starting
    assert_includes active_processes, running
    assert_includes active_processes, unhealthy
    assert_not_includes active_processes, stopped
  end

  # Purpose: Validates needs_attention scope includes crashed and unhealthy
  # Can fail if: Scope definition broken
  test "needs_attention scope includes crashed and unhealthy processes" do
    crashed = XmrigProcess.create!(hostname: "host1", worker_id: "w1", status: "crashed")
    unhealthy = XmrigProcess.create!(hostname: "host2", worker_id: "w2", status: "unhealthy")
    running = XmrigProcess.create!(hostname: "host3", worker_id: "w3", status: "running")

    attention_needed = XmrigProcess.needs_attention

    assert_includes attention_needed, crashed
    assert_includes attention_needed, unhealthy
    assert_not_includes attention_needed, running
  end

  # Purpose: Validates status inclusion validation
  # Can fail if: Status validation not enforced
  test "validates status is in allowed values" do
    process = XmrigProcess.new(hostname: "test", worker_id: "test", status: "invalid_status")

    assert_not process.valid?
    assert_includes process.errors[:status], "is not included in the list"
  end

  # Purpose: Validates required fields
  # Can fail if: Presence validations not enforced
  test "validates presence of required fields" do
    process = XmrigProcess.new

    assert_not process.valid?
    assert_includes process.errors[:hostname], "can't be blank"
    assert_includes process.errors[:worker_id], "can't be blank"
  end
end
