module Modal
  class SandboxFile
    attr_reader :file_descriptor, :task_id

    def initialize(file_descriptor, task_id)
      @file_descriptor = file_descriptor
      @task_id = task_id
    end

    def read
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_read_request: Modal::Client::ContainerFileReadRequest.new(
          file_descriptor: @file_descriptor
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      data = ""
      completed = false
      retries = 20

      while !completed && retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 10
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:output) && batch.output && batch.output.any?
              chunk = if batch.output.first.is_a?(String)
                batch.output.join("")
              elsif batch.output.first.is_a?(Integer)
                batch.output.pack("C*")
              else
                batch.output.map(&:to_s).join("")
              end

              data += chunk.force_encoding("UTF-8")
            end

            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Read failed: #{batch.error.error_message}")
            end

            if batch.respond_to?(:eof) && batch.eof
              completed = true
              break
            end
          end

          unless completed
            retries -= 1
            sleep(0.1)
          end
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            sleep(0.1)
            next
          else
            raise e
          end
        end
      end

      data
    end

    def write(data)
      binary_data = if data.is_a?(String)
        data.force_encoding("BINARY")
      else
        data.to_s.force_encoding("BINARY")
      end

      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_write_request: Modal::Client::ContainerFileWriteRequest.new(
          file_descriptor: @file_descriptor,
          data: binary_data
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      completed = false
      retries = 20

      while !completed && retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 10
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Write failed: #{batch.error.error_message}")
            end
            if batch.respond_to?(:eof) && batch.eof
              completed = true
              break
            end
          end

          unless completed
            retries -= 1
            sleep(0.1)
          end
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            sleep(0.1)
            next
          else
            raise e
          end
        end
      end

      unless completed
      end

      data.length
    end

    def flush
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_flush_request: Modal::Client::ContainerFileFlushRequest.new(
          file_descriptor: @file_descriptor
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      retries = 10

      while retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 5
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)
          stream.each do |batch|
            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Flush failed: #{batch.error.error_message}")
            end
            if batch.respond_to?(:eof) && batch.eof
              return
            end
          end

          retries -= 1
          sleep(0.1)
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            next
          else
            raise e
          end
        end
      end
    end

    def seek(offset, whence = 0)
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_seek_request: Modal::Client::ContainerFileSeekRequest.new(
          file_descriptor: @file_descriptor,
          offset: offset,
          whence: whence
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      retries = 10
      position = nil

      while retries > 0 && position.nil?
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 10
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:output) && batch.output && batch.output.any?
              position_data = if batch.output.first.is_a?(String)
                batch.output.join("")
              elsif batch.output.first.is_a?(Integer)
                batch.output.pack("C*")
              else
                batch.output.map(&:to_s).join("")
              end
              
              position = position_data.to_i
            end

            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Seek failed: #{batch.error.error_message}")
            end

            if batch.respond_to?(:eof) && batch.eof
              break
            end
          end

          retries -= 1
          sleep(0.1) unless position
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            sleep(0.1)
            next
          else
            raise e
          end
        end
      end

      position || offset
    end

    def tell
      # Tell is typically implemented by seeking with offset 0 and SEEK_CUR
      seek(0, 1) # SEEK_CUR = 1
    end

    def truncate(length = nil)
      # Truncation can be implemented by writing empty data at the specified length
      # This is a simplified implementation
      if length.nil?
        current_pos = tell
        length = current_pos
      end
      
      # For now, return the length as this operation may not be fully supported
      puts "Warning: truncate() may not be fully implemented"
      length
    end

    def readline
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_read_line_request: Modal::Client::ContainerFileReadLineRequest.new(
          file_descriptor: @file_descriptor
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      data = ""
      completed = false
      retries = 20

      while !completed && retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 10
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:output) && batch.output && batch.output.any?
              chunk = if batch.output.first.is_a?(String)
                batch.output.join("")
              elsif batch.output.first.is_a?(Integer)
                batch.output.pack("C*")
              else
                batch.output.map(&:to_s).join("")
              end

              data += chunk.force_encoding("UTF-8")
            end

            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Readline failed: #{batch.error.error_message}")
            end

            if batch.respond_to?(:eof) && batch.eof
              completed = true
              break
            end
          end

          unless completed
            retries -= 1
            sleep(0.1)
          end
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            sleep(0.1)
            next
          else
            raise e
          end
        end
      end

      data
    end

    def close
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_close_request: Modal::Client::ContainerFileCloseRequest.new(
          file_descriptor: @file_descriptor
        ),
        task_id: @task_id
      )

      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id

      retries = 10

      while retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 5
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)
          stream.each do |batch|
            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Close failed: #{batch.error.error_message}")
            end
            if batch.respond_to?(:eof) && batch.eof
              return
            end
          end

          retries -= 1
          sleep(0.1)
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            next
          else
            raise e
          end
        end
      end
    end
  end
end
