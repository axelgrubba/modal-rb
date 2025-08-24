module Modal
  class Secret
    attr_reader :secret_id

    def initialize(secret_id)
      @secret_id = secret_id
    end

    def self.from_name(name, environment_name = nil)
      request = Modal::Client::SecretGetOrCreateRequest.new(
        deployment_name: name,
        environment_name: Modal::Config.environment_name(environment_name),
        object_creation_type: Modal::Client::ObjectCreationType::OBJECT_CREATION_TYPE_UNSPECIFIED
      )

      resp = Modal.client.call(:secret_get_or_create, request)
      new(resp.secret_id)
    end

    def self.from_dict(env_dict, name: nil, environment_name: nil)
      request = Modal::Client::SecretGetOrCreateRequest.new(
        deployment_name: name || "ruby-secret-#{rand(10000)}",
        environment_name: Modal::Config.environment_name(environment_name),
        object_creation_type: Modal::Client::ObjectCreationType::OBJECT_CREATION_TYPE_CREATE_IF_MISSING
      )

      # Convert hash to protobuf repeated field
      env_dict.each do |key, value|
        request.env_dict[key.to_s] = value.to_s
      end

      resp = Modal.client.call(:secret_get_or_create, request)
      new(resp.secret_id)
    end
  end
end