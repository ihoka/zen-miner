# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../../host-daemon/lib/installer/config_generator'

class ConfigGeneratorTest < Minitest::Test
  def setup
    @logger = mock_logger
    @generator = Installer::ConfigGenerator.new(logger: @logger)
  end

  def test_execute_success_with_required_env_vars
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'worker-1') do
      written_content = nil

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        # Capture the content being written
        if cmd.include?('cat >')
          written_content = cmd.split("'EOF'\n")[1]&.split("\nEOF")[0]
        end
        ["", "", mock_status(true)]
      } do
        result = @generator.execute

        assert result.success?
        assert_equal "XMRig configuration generated", result.message

        # Verify content was written
        refute_nil written_content, "Config content should have been written"

        # Parse and validate JSON
        config = JSON.parse(written_content)
        assert_equal '4' + 'A' * 94, config['pools'][0]['user']
        assert_equal 'worker-1', config['pools'][0]['pass']
        assert_equal 'pool.hashvault.pro:443', config['pools'][0]['url']  # Default
        assert_equal 50, config['cpu']['max-threads-hint']  # Default
      end
    end
  end

  def test_execute_uses_custom_pool_url
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'worker-1', 'POOL_URL' => 'pool.supportxmr.com:3333') do
      written_content = nil

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('cat >')
          written_content = cmd.split("'EOF'\n")[1]&.split("\nEOF")[0]
        end
        ["", "", mock_status(true)]
      } do
        result = @generator.execute

        assert result.success?

        config = JSON.parse(written_content)
        assert_equal 'pool.supportxmr.com:3333', config['pools'][0]['url']
      end
    end
  end

  def test_execute_uses_custom_cpu_threads_hint
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'worker-1', 'CPU_MAX_THREADS_HINT' => '75') do
      written_content = nil

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('cat >')
          written_content = cmd.split("'EOF'\n")[1]&.split("\nEOF")[0]
        end
        ["", "", mock_status(true)]
      } do
        result = @generator.execute

        assert result.success?

        config = JSON.parse(written_content)
        assert_equal 75, config['cpu']['max-threads-hint']
      end
    end
  end

  def test_execute_generates_valid_json_structure
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'test-worker') do
      written_content = nil

      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('cat >')
          written_content = cmd.split("'EOF'\n")[1]&.split("\nEOF")[0]
        end
        ["", "", mock_status(true)]
      } do
        result = @generator.execute

        assert result.success?

        config = JSON.parse(written_content)

        # Verify structure
        assert config['autosave']
        assert config['http']['enabled']
        assert_equal '127.0.0.1', config['http']['host']
        assert_equal 8080, config['http']['port']
        assert config['http']['restricted']

        # Verify pool config
        assert_equal 1, config['pools'].length
        assert config['pools'][0]['tls']
        assert config['pools'][0]['keepalive']

        # Verify CPU config
        assert config['cpu']['enabled']
        assert config['cpu']['huge-pages']
        assert_equal 1, config['cpu']['priority']

        # Verify GPU disabled
        refute config['opencl']['enabled']
        refute config['cuda']['enabled']

        # Verify donate level
        assert_equal 1, config['donate-level']
      end
    end
  end

  def test_execute_fails_when_write_fails
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'worker-1') do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('cat >')
          ["", "Permission denied", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @generator.execute

        assert result.failure?
        assert_includes result.message, "Failed to write config file"
      end
    end
  end

  def test_execute_fails_when_mv_fails
    with_env('MONERO_WALLET' => '4' + 'A' * 94, 'WORKER_ID' => 'worker-1') do
      Open3.stub :capture3, lambda { |*args|
        cmd = args.join(' ')
        if cmd.include?('mv')
          ["", "Cannot move file", mock_status(false)]
        else
          ["", "", mock_status(true)]
        end
      } do
        result = @generator.execute

        assert result.failure?
        assert_includes result.message, "Failed to move config file"
      end
    end
  end

  def test_completed_returns_true_when_config_exists
    @generator.stub :file_exists?, true do
      assert @generator.completed?, "Should be completed when config file exists"
    end
  end

  def test_completed_returns_false_when_config_missing
    @generator.stub :file_exists?, false do
      refute @generator.completed?, "Should not be completed when config file is missing"
    end
  end

  def test_config_file_path_is_correct
    assert_equal '/etc/xmrig/config.json', Installer::ConfigGenerator::CONFIG_FILE
  end

  def test_default_pool_url_is_hashvault
    assert_equal 'pool.hashvault.pro:443', Installer::ConfigGenerator::DEFAULT_POOL_URL
  end

  def test_default_cpu_threads_is_50
    assert_equal 50, Installer::ConfigGenerator::DEFAULT_CPU_MAX_THREADS_HINT
  end

  private

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end
end
