module Modal
  class Tunnel
    attr_reader :host, :port, :unencrypted_host, :unencrypted_port

    def initialize(host, port, unencrypted_host, unencrypted_port)
      @host = host
      @port = port
      @unencrypted_host = unencrypted_host
      @unencrypted_port = unencrypted_port
    end

    def url
      value = "https://#{@host}"
      value += ":#{@port}" if @port != 443
      value
    end

    def tls_socket
      [@host, @port]
    end

    def tcp_socket
      if @unencrypted_host.nil? || @unencrypted_host.empty?
        raise Modal::InvalidError, "This tunnel is not configured for unencrypted TCP. Please use unencrypted_ports option."
      end
      [@unencrypted_host, @unencrypted_port]
    end
  end
end