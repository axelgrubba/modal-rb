require "modal"

def main
  app = Modal::App.lookup("my-modal-app")
  puts "Found app: #{app.app_id}"
  image = app.image_from_registry("python:3.11-slim")
  puts "Using image: #{image.image_id}"
  
  # Create a sandbox with port forwarding
  sandbox = app.create_sandbox(
    image, 
    timeout: 30000, 
    cpu: 0.5, 
    memory: 256, 
    command: ["python", "-m", "http.server", "12345"],
    encrypted_ports: [12345]
  )
  puts "Created sandbox with ID: #{sandbox.sandbox_id}"
  
  # Wait a moment for the server to start
  sleep(2)
  
  # Get the tunnels (public URLs)
  tunnels = sandbox.tunnels
  tunnel = tunnels[12345]
  
  if tunnel
    puts "Server accessible at: #{tunnel.url}"
    puts "TLS socket: #{tunnel.tls_socket.join(':')}"
    
    # You could make a request to the URL here
    # require 'net/http'
    # uri = URI(tunnel.url)
    # response = Net::HTTP.get_response(uri)
    # puts "Response: #{response.code} #{response.message}"
  else
    puts "No tunnel found for port 12345"
  end
  
  sandbox.terminate
end

main