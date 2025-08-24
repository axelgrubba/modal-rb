module Modal
  class App
    attr_reader :app_id

    def initialize(app_id)
      @app_id = app_id
    end

    def self.lookup(name, options = {})
      create_if_missing = options[:create_if_missing] || false
      environment = options[:environment]

      request = Modal::Client::AppGetOrCreateRequest.new(
        app_name: name,
        environment_name: Config.environment_name(environment),
        object_creation_type: create_if_missing ? Modal::Client::ObjectCreationType::OBJECT_CREATION_TYPE_CREATE_IF_MISSING : Modal::Client::ObjectCreationType::OBJECT_CREATION_TYPE_UNSPECIFIED
      )

      resp = Modal.client.call(:app_get_or_create, request)
      new(resp.app_id)
    end

    def create_sandbox(image, options = {})
      timeout_secs = options[:timeout] ? options[:timeout] / 1000 : 600
      cpu_milli = (options[:cpu] || 0.125) * 1000
      memory_mb = options[:memory] || 128
      command = options[:command] || ["sleep", "48h"]
      encrypted_ports = options[:encrypted_ports] || []
      unencrypted_ports = options[:unencrypted_ports] || []
      h2_ports = options[:h2_ports] || []
      secrets = options[:secrets] || []

      # Build open_ports array from port specifications
      open_ports = []
      encrypted_ports.each do |port|
        open_ports << Modal::Client::PortSpec.new(port: port, unencrypted: false)
      end
      unencrypted_ports.each do |port|
        open_ports << Modal::Client::PortSpec.new(port: port, unencrypted: true)
      end
      h2_ports.each do |port|
        open_ports << Modal::Client::PortSpec.new(
          port: port, 
          unencrypted: false, 
          tunnel_type: Modal::Client::TunnelType::TUNNEL_TYPE_H2
        )
      end

      # Extract secret IDs from Secret objects
      secret_ids = secrets.map do |secret|
        case secret
        when Secret
          secret.secret_id
        when String
          secret
        else
          raise TypeError, "secrets must contain Secret objects or strings, got #{secret.class}"
        end
      end

      request = Modal::Client::SandboxCreateRequest.new(
        app_id: @app_id,
        definition: Modal::Client::Sandbox.new(
          entrypoint_args: command,
          image_id: image.image_id,
          timeout_secs: timeout_secs,
          network_access: Modal::Client::NetworkAccess.new(
            network_access_type: Modal::Client::NetworkAccess::NetworkAccessType::OPEN
          ),
          resources: Modal::Client::Resources.new(
            milli_cpu: cpu_milli.round,
            memory_mb: memory_mb.round
          ),
          open_ports: Modal::Client::PortSpecs.new(ports: open_ports),
          secret_ids: secret_ids
        )
      )

      create_resp = Modal.client.call(:sandbox_create, request)
      Sandbox.new(create_resp.sandbox_id)
    end

    def image_from_registry(tag)
      Image.from_registry_internal(@app_id, tag)
    end

    def image_from_dockerfile(dockerfile_path, options = {})
      options = options.merge(app_id: @app_id)
      Image.from_dockerfile(dockerfile_path, options)
    end

    def image_from_aws_ecr(tag, secret)
      unless secret.is_a?(Secret)
        raise TypeError, "secret must be a reference to an existing Secret, e.g. `Secret.from_name('my_secret')`"
      end

      image_registry_config = Modal::Client::ImageRegistryConfig.new(
        registry_auth_type: Modal::Client::RegistryAuthType::REGISTRY_AUTH_TYPE_AWS,
        secret_id: secret.secret_id
      )
      Image.from_registry_internal(@app_id, tag, image_registry_config)
    end
  end
end
