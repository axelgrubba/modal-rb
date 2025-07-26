require "modal"

def main
  app = Modal::App.lookup("my-modal-app")
  puts "Found app: #{app.app_id}"
rescue Modal::NotFoundError => e
  puts "Modal app not found (#{e.message})."
end

main
