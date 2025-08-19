module Modal
  class Image
    attr_reader :image_id

    def initialize(image_id)
      @image_id = image_id
    end

    def self.from_dockerfile(dockerfile_path, options = {})
      force_build = options[:force_build] || false
      secrets = options[:secrets] || []
      build_args = options[:build_args] || {}
      app_id = options[:app_id]

      dockerfile_path = File.expand_path(dockerfile_path)
      raise InvalidError, "Dockerfile not found at #{dockerfile_path}" unless File.exist?(dockerfile_path)

      dockerfile_commands = File.read(dockerfile_path).split("\n")

      request = Modal::Client::ImageGetOrCreateRequest.new(
        image: Modal::Client::Image.new(
          dockerfile_commands: dockerfile_commands,
          build_args: build_args
        ),
        namespace: Modal::Client::DeploymentNamespace::DEPLOYMENT_NAMESPACE_WORKSPACE,
        builder_version: Config.image_builder_version,
        force_build: force_build
      )

      request.app_id = app_id if app_id

      if secrets && !secrets.empty?
        request.secret_ids.concat(secrets.map(&:secret_id))
      end

      resp = Modal.client.call(:image_get_or_create, request)
      result = resp.result

      if result && result.status != :GENERIC_STATUS_UNSPECIFIED
        # Build completed immediately
      else
        # Wait for build to complete
        last_entry_id = ""

        loop do
          streaming_request = Modal::Client::ImageJoinStreamingRequest.new(
            image_id: resp.image_id,
            timeout: 55,
            last_entry_id: last_entry_id
          )

          puts "Building image #{resp.image_id}..."

          begin
            stream_resp = Modal.client.call(:image_join_streaming, streaming_request)

            if stream_resp.result && stream_resp.result.status != Modal::Client::GenericResult::GenericStatus::GENERIC_STATUS_UNSPECIFIED
              result = stream_resp.result
              break
            end

            if stream_resp.entry_id && !stream_resp.entry_id.empty?
              last_entry_id = stream_resp.entry_id
            end
          rescue => e
            puts "Error checking build status: #{e.message}"
            sleep(5)
            next
          end

          sleep(2)
        end
      end

      case result.status
      when :GENERIC_STATUS_FAILURE
        raise "Image build for #{resp.image_id} failed with exception:\n#{result.exception}"
      when :GENERIC_STATUS_TERMINATED
        raise "Image build for #{resp.image_id} terminated due to external shut-down. Please try again."
      when :GENERIC_STATUS_TIMEOUT
        raise "Image build for #{resp.image_id} timed out. Please try again with a larger timeout parameter."
      when :GENERIC_STATUS_SUCCESS
        new(resp.image_id)
      else
        raise "Image build for #{resp.image_id} failed with unknown status: #{result.status}"
      end
    end

    def self.from_registry_internal(app_id, tag, image_registry_config = nil)
      request = Modal::Client::ImageGetOrCreateRequest.new(
        app_id: app_id,
        image: Modal::Client::Image.new(
          dockerfile_commands: ["FROM #{tag}"],
          image_registry_config: image_registry_config
        ),
        namespace: Modal::Client::DeploymentNamespace::DEPLOYMENT_NAMESPACE_WORKSPACE,
        builder_version: Config.image_builder_version
      )

      resp = Modal.client.call(:image_get_or_create, request)
      result = resp.result
      metadata = resp.metadata

      if result && result.status != :GENERIC_STATUS_UNSPECIFIED
        metadata = resp.metadata
      else
        last_entry_id = ""

        loop do
          streaming_request = Modal::Client::ImageJoinStreamingRequest.new(
            image_id: resp.image_id,
            timeout: 55,
            last_entry_id: last_entry_id
          )

          puts "Waiting for image build for #{resp.image_id}..."

          begin
            stream_resp = Modal.client.call(:image_join_streaming, streaming_request)

            if stream_resp.result && stream_resp.result.status != Modal::Client::GenericResult::GenericStatus::GENERIC_STATUS_UNSPECIFIED
              result = stream_resp.result
              metadata = stream_resp.metadata
              break
            end

            if stream_resp.entry_id && !stream_resp.entry_id.empty?
              last_entry_id = stream_resp.entry_id
            end
          rescue => e
            puts "Error checking build status: #{e.message}"
            sleep(5)
            next
          end

          sleep(2) # Wait before next check
        end
      end

      case result.status
      when :GENERIC_STATUS_FAILURE
        raise "Image build for #{resp.image_id} failed with the exception:\n#{result.exception}"
      when :GENERIC_STATUS_TERMINATED
        raise "Image build for #{resp.image_id} terminated due to external shut-down. Please try again."
      when :GENERIC_STATUS_TIMEOUT
        raise "Image build for #{resp.image_id} timed out. Please try again with a larger timeout parameter."
      when :GENERIC_STATUS_SUCCESS
        new(resp.image_id)
      else
        raise "Image build for #{resp.image_id} failed with unknown status: #{result.status}"
      end
    end
  end
end
