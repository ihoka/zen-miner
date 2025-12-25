# frozen_string_literal: true

require_relative "test_helper"
require_relative "../../host-daemon/lib/installer/prerequisite_checker"

class PrerequisiteCheckerTest < Minitest::Test
  def setup
    @logger = mock_logger
    @checker = Installer::PrerequisiteChecker.new(logger: @logger)
  end

  def test_execute_success_when_all_prerequisites_met
    with_env("MONERO_WALLET" => "4" + "A" * 94, "WORKER_ID" => "test-worker") do
      # Stub command_exists? to return true for all commands
      @checker.stub :command_exists?, true do
        # Mock Open3 commands
        Open3.stub :capture3, lambda { |*args|
          cmd = args.join(" ")
          if cmd.include?("sudo -v")
            ["", "", mock_status(true)]
          elsif cmd.include?("gem list -i bundler")
            ["", "", mock_status(true)]
          elsif cmd.include?("bundler/inline")
            ["", "", mock_status(true)]
          else
            ["", "", mock_status(false)]
          end
        } do
          result = @checker.execute

          assert result.success?, "Expected success, got: #{result.message}"
          assert_equal "All prerequisites met", result.message
        end
      end
    end
  end

  def test_execute_fails_without_sudo
    @checker.stub :command_exists?, lambda { |cmd| cmd != "sudo" } do
      result = @checker.execute

      assert result.failure?
      assert_includes result.message, "sudo not found"
      assert_equal "sudo", result.data[:missing_command]
    end
  end

  def test_execute_fails_without_sudo_privileges
    @checker.stub :command_exists?, true do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(" ")
        if cmd.include?("sudo -v")
          ["", "", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @checker.execute

        assert result.failure?
        assert_includes result.message, "Unable to obtain sudo privileges"
      end
    end
  end

  def test_execute_fails_without_ruby
    @checker.stub :command_exists?, lambda { |cmd| cmd != "ruby" } do
      Open3.stub :capture3, lambda { |*args|
        ["", "", mock_status(true)]
      } do
        result = @checker.execute

        assert result.failure?
        assert_includes result.message, "ruby not found"
        assert_equal "ruby", result.data[:missing_command]
      end
    end
  end

  def test_execute_fails_without_xmrig
    @checker.stub :command_exists?, lambda { |cmd| cmd != "xmrig" } do
      Open3.stub :capture3, lambda { |*args|
        ["", "", mock_status(true)]
      } do
        result = @checker.execute

        assert result.failure?
        assert_includes result.message, "xmrig not found"
        assert_equal "xmrig", result.data[:missing_command]
      end
    end
  end

  def test_execute_fails_without_monero_wallet
    # Clear MONERO_WALLET and set WORKER_ID
    old_wallet = ENV.delete("MONERO_WALLET")
    with_env("WORKER_ID" => "test-worker") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.failure?
          assert_includes result.message, "Missing required environment variables"
          assert_includes result.data[:missing_env_vars], "MONERO_WALLET"
        end
      end
    end
  ensure
    ENV["MONERO_WALLET"] = old_wallet if old_wallet
  end

  def test_execute_fails_without_worker_id
    # Clear WORKER_ID and set MONERO_WALLET
    old_worker = ENV.delete("WORKER_ID")
    with_env("MONERO_WALLET" => "4" + "A" * 94) do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.failure?
          assert_includes result.message, "Missing required environment variables"
          assert_includes result.data[:missing_env_vars], "WORKER_ID"
        end
      end
    end
  ensure
    ENV["WORKER_ID"] = old_worker if old_worker
  end

  def test_validate_monero_wallet_accepts_standard_address
    # Standard address: starts with 4, 95 chars
    wallet = "4" + "A" * 94

    with_env("MONERO_WALLET" => wallet, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.success?, "Standard address should be valid"
        end
      end
    end
  end

  def test_validate_monero_wallet_accepts_subaddress
    # Subaddress: starts with 8, 95 chars
    wallet = "8" + "B" * 94

    with_env("MONERO_WALLET" => wallet, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.success?, "Subaddress should be valid"
        end
      end
    end
  end

  def test_validate_monero_wallet_accepts_integrated_address
    # Integrated address: starts with 4, 106 chars
    wallet = "4" + "C" * 105

    with_env("MONERO_WALLET" => wallet, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.success?, "Integrated address should be valid"
        end
      end
    end
  end

  def test_validate_monero_wallet_rejects_invalid_format
    # Wrong starting character
    invalid_wallet = "9" + "A" * 94

    with_env("MONERO_WALLET" => invalid_wallet, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.failure?
          assert_includes result.message, "Invalid Monero wallet address"
        end
      end
    end
  end

  def test_validate_monero_wallet_rejects_wrong_length
    # Wrong length (too short)
    invalid_wallet = "4" + "A" * 50

    with_env("MONERO_WALLET" => invalid_wallet, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          ["", "", mock_status(true)]
        } do
          result = @checker.execute

          assert result.failure?
          assert_includes result.message, "Invalid Monero wallet address"
        end
      end
    end
  end

  def test_installs_bundler_if_missing
    with_env("MONERO_WALLET" => "4" + "A" * 94, "WORKER_ID" => "test") do
      @checker.stub :command_exists?, true do
        Open3.stub :capture3, lambda { |*args|
          cmd = args.join(" ")
          if cmd.include?("gem list -i bundler")
            ["", "", mock_status(false)]  # Bundler not installed
          else
            ["", "", mock_status(true)]   # Other commands succeed
          end
        } do
          result = @checker.execute

          assert result.success?, "Expected success after installing bundler"

          # Verify logger shows bundler installation
          messages = @logger.messages.map { |_, msg| msg }
          assert messages.any? { |msg| msg.include?("Installing bundler") },
                 "Expected to see 'Installing bundler' message"
        end
      end
    end
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
