require_relative "test_helper"

class TestAppSandbox < Minitest::Test
  def test_app_lookup_with_create_if_missing
    with_mocked_client do
      app_name = "test_app_#{Time.now.to_i}"
      mock_response = Minitest::Mock.new
      mock_response.expect(:app_id, "app_123")
      expected_request = Modal::Client::AppGetOrCreateRequest.new(
        app_name: app_name,
        environment_name: Modal::Config.environment_name
      )
      mock_api_client.expect(:call, mock_response, [:app_get_or_create, expected_request])
      response = mock_api_client.call(:app_get_or_create, expected_request)
      assert_equal "app_123", response.app_id
      mock_api_client.verify
    end
  end

  def test_app_lookup_without_create_if_missing
    with_mocked_client do
      app_name = "existing_app"
      mock_response = Minitest::Mock.new
      mock_response.expect(:app_id, "app_456")
      expected_request = Modal::Client::AppGetOrCreateRequest.new(
        app_name: app_name,
        environment_name: Modal::Config.environment_name
      )
      mock_api_client.expect(:call, mock_response, [:app_get_or_create, expected_request])
      response = mock_api_client.call(:app_get_or_create, expected_request)
      assert_equal "app_456", response.app_id
      mock_api_client.verify
    end
  end

  def test_tunnel_url_generation
    tunnel = Modal::Tunnel.new("example.com", 443, "tcp.example.com", 8080)
    assert_equal "https://example.com", tunnel.url

    tunnel_custom_port = Modal::Tunnel.new("example.com", 8443, nil, nil)
    assert_equal "https://example.com:8443", tunnel_custom_port.url
  end

  def test_tunnel_tcp_socket_error
    tunnel = Modal::Tunnel.new("example.com", 443, "", 0)
    assert_raises(Modal::InvalidError) do
      tunnel.tcp_socket
    end

    tunnel_with_tcp = Modal::Tunnel.new("example.com", 443, "tcp.example.com", 8080)
    assert_equal ["tcp.example.com", 8080], tunnel_with_tcp.tcp_socket
  end

  def test_sandbox_tunnels_caching
    sandbox = Modal::Sandbox.new("sandbox_123")

    cache_test_result = {8080 => Modal::Tunnel.new("example.com", 443, "", 0)}
    sandbox.instance_variable_set(:@tunnels_cache, cache_test_result)

    tunnels = sandbox.tunnels
    assert_equal cache_test_result, tunnels
    assert_instance_of Modal::Tunnel, tunnels[8080]
    assert_equal "https://example.com", tunnels[8080].url
  end
end
