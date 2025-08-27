require_relative "sandbox_filesystem"
require_relative "streams"
require "ostruct"

module Modal
  class Sandbox
    attr_reader :sandbox_id, :stdin, :stdout, :stderr
    attr_accessor :task_id

    def initialize(sandbox_id)
      @sandbox_id = sandbox_id
      @task_id = nil
      @tunnels_cache = nil
      @exit_code = nil
      @completed = false

      @stdin = ModalWriteStream.new(SandboxInputStream.new(sandbox_id))
      @stdout = ModalReadStream.new(SandboxOutputStream.new(sandbox_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDOUT))
      @stderr = ModalReadStream.new(SandboxOutputStream.new(sandbox_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDERR))
    end

    def exec(command, options = {})
      ensure_task_id

      workdir = options[:workdir]
      timeout_secs = options[:timeout] ? options[:timeout] / 1000 : 0

      request = Modal::Client::ContainerExecRequest.new(
        task_id: @task_id,
        command: command,
        workdir: workdir,
        timeout_secs: timeout_secs
      )

      resp = Modal.client.call(:container_exec, request)
      ContainerProcess.new(resp.exec_id, "text")
    end

    def open(path, mode)
      ensure_task_id

      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_open_request: Modal::Client::ContainerFileOpenRequest.new(
          path: path,
          mode: mode
        ),
        task_id: @task_id
      )
      resp = run_filesystem_exec(request)
      SandboxFile.new(resp.response.file_open_response.file_descriptor, @task_id)
    end

    def ls(path)
      ensure_task_id
      
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_ls_request: Modal::Client::ContainerFileLsRequest.new(
          path: path
        ),
        task_id: @task_id
      )
      resp = run_filesystem_exec(request)
      
      # Parse the output to get list of files/directories
      output = resp.response.output || []
      files = []
      output.each do |line|
        next if line.strip.empty?
        files << line.strip
      end
      files
    end

    def mkdir(path, options = {})
      ensure_task_id
      parents = options[:parents] || false
      
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_mkdir_request: Modal::Client::ContainerFileMkdirRequest.new(
          path: path,
          make_parents: parents
        ),
        task_id: @task_id
      )
      run_filesystem_exec(request)
      nil
    end

    def rm(path, options = {})
      ensure_task_id
      recursive = options[:recursive] || false
      
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_rm_request: Modal::Client::ContainerFileRmRequest.new(
          path: path,
          recursive: recursive
        ),
        task_id: @task_id
      )
      run_filesystem_exec(request)
      nil
    end

    def copy_from(remote_path, local_path, options = {})
      ensure_task_id
      
      # Check if remote path exists
      begin
        file = open(remote_path, "r")
        content = file.read
        file.close
        
        # Write to local file
        File.open(local_path, "w") { |f| f.write(content) }
        
        return content.length
      rescue => e
        raise Modal::SandboxFilesystemError.new("Failed to copy file: #{e.message}")
      end
    end

    def download_archive(paths, local_file, options = {})
      ensure_task_id
      
      # Create temporary archive in sandbox
      archive_path = "/tmp/modal_download_#{Time.now.to_f.to_s.gsub('.', '')}.tar.gz"
      
      # Build tar command
      cmd = ["tar", "-czf", archive_path] + Array(paths)
      result = exec(cmd)
      exit_code = result.wait
      
      if exit_code != 0
        raise Modal::SandboxFilesystemError.new("Failed to create archive (exit code: #{exit_code})")
      end
      
      # Read archive and write locally
      archive_file = open(archive_path, "rb")
      archive_data = archive_file.read
      archive_file.close
      
      # Clean up remote archive
      exec(["rm", archive_path]).wait rescue nil
      
      # Write to local file
      File.open(local_file, "wb") { |f| f.write(archive_data) }
      
      archive_data.length
    end

    def terminate
      request = Modal::Client::SandboxTerminateRequest.new(sandbox_id: @sandbox_id)
      Modal.client.call(:sandbox_terminate, request)
    end

    def wait
      loop do
        request = Modal::Client::SandboxWaitRequest.new(
          sandbox_id: @sandbox_id,
          timeout: 55 # seconds
        )
        resp = Modal.client.call(:sandbox_wait, request)
        if resp.result && resp.result.status != :GENERIC_STATUS_UNSPECIFIED
          @completed = true
          @exit_code = resp.result.exitcode || 0
          return @exit_code
        end
        sleep(1) # Poll every second
      end
    end

    def poll
      return @exit_code if @completed

      request = Modal::Client::SandboxWaitRequest.new(
        sandbox_id: @sandbox_id,
        timeout: 1 # Short timeout for non-blocking behavior
      )
      resp = Modal.client.call(:sandbox_wait, request)
      if resp.result && resp.result.status != :GENERIC_STATUS_UNSPECIFIED
        @completed = true
        @exit_code = resp.result.exitcode || 0
        return @exit_code
      end
      nil # Still running
    end

    def returncode
      return @exit_code if @completed
      poll # Check current status
    end

    def tunnels(timeout: 50)
      return @tunnels_cache if @tunnels_cache

      request = Modal::Client::SandboxGetTunnelsRequest.new(
        sandbox_id: @sandbox_id,
        timeout: timeout
      )

      resp = Modal.client.call(:sandbox_get_tunnels, request)

      # Check if we got a timeout
      if resp.result.status == Modal::Client::GenericResult::GenericStatus::GENERIC_STATUS_TIMEOUT
        raise Modal::SandboxTimeoutError, "Timeout waiting for tunnels to be ready"
      end

      # Build tunnels hash keyed by container port
      @tunnels_cache = {}
      resp.tunnels.each do |tunnel_data|
        @tunnels_cache[tunnel_data.container_port] = Tunnel.new(
          tunnel_data.host,
          tunnel_data.port,
          tunnel_data.unencrypted_host,
          tunnel_data.unencrypted_port
        )
      end

      @tunnels_cache
    end

    def watch(path, options = {}, &block)
      ensure_task_id
      
      timeout = options[:timeout] || 0
      recursive = options[:recursive] || false
      filter_events = options[:filter] || []
      
      request = Modal::Client::ContainerFilesystemExecRequest.new(
        file_watch_request: Modal::Client::ContainerFileWatchRequest.new(
          path: path,
          timeout_secs: timeout,
          recursive: recursive
        ),
        task_id: @task_id
      )
      
      resp = Modal.client.call(:container_filesystem_exec, request)
      exec_id = resp.exec_id
      
      if block_given?
        watch_with_callback(exec_id, &block)
      else
        watch_events(exec_id)
      end
    end

    private

    def watch_with_callback(exec_id, &block)
      Thread.new do
        begin
          events = watch_events(exec_id)
          events.each { |event| block.call(event) }
        rescue => e
          puts "Watch error: #{e.message}"
        end
      end
    end

    def watch_events(exec_id)
      events = []
      completed = false
      retries = 10

      while !completed && retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 30
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:output) && batch.output && batch.output.any?
              batch.output.each do |event_data|
                event = parse_watch_event(event_data)
                events << event if event
              end
            end

            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new("Watch failed: #{batch.error.error_message}")
            end

            if batch.respond_to?(:eof) && batch.eof
              completed = true
              break
            end
          end

          retries -= 1 unless completed
          sleep(0.5) unless completed
        rescue GRPC::BadStatus => e
          if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
            retries -= 1
            sleep(1.0)
            next
          else
            raise e
          end
        end
      end

      events
    end

    def parse_watch_event(event_data)
      begin
        require 'json'
        
        event_str = if event_data.is_a?(String)
          event_data
        elsif event_data.is_a?(Integer) || event_data.is_a?(Array)
          Array(event_data).pack("C*").force_encoding("UTF-8")
        else
          event_data.to_s
        end
        
        event_json = JSON.parse(event_str)
        
        FileWatchEvent.new(
          type: event_json['event_type'],
          paths: event_json['paths'] || []
        )
      rescue JSON::ParserError, StandardError
        nil # Skip invalid events
      end
    end

    # Helper to run filesystem exec requests and handle output.
    def run_filesystem_exec(request)
      response = Modal.client.call(:container_filesystem_exec, request)
      if response.respond_to?(:file_descriptor) && response.file_descriptor
        return OpenStruct.new(
          response: OpenStruct.new(
            file_open_response: OpenStruct.new(
              file_descriptor: response.file_descriptor
            )
          )
        )
      end

      exec_id = response.exec_id
      retries = 10

      while retries > 0
        begin
          output_request = Modal::Client::ContainerFilesystemExecGetOutputRequest.new(
            exec_id: exec_id,
            timeout: 10
          )

          stream = Modal.client.call(:container_filesystem_exec_get_output, output_request)

          stream.each do |batch|
            if batch.respond_to?(:error) && batch.error
              raise SandboxFilesystemError.new(batch.error.error_message)
            end

            if batch.respond_to?(:eof) && batch.eof
              return OpenStruct.new(response: response)
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

      raise SandboxFilesystemError.new("Filesystem operation timed out")
    end

    def ensure_task_id
      return if @task_id

      request = Modal::Client::SandboxGetTaskIdRequest.new(
        sandbox_id: @sandbox_id,
        wait_until_ready: true
      )
      resp = Modal.client.call(:sandbox_get_task_id, request)

      if resp.task_id && !resp.task_id.empty?
        @task_id = resp.task_id
      else
        raise "Sandbox #{@sandbox_id} does not have a task ID, it may not be running"
      end
    end
  end

  class ContainerProcess
    attr_reader :exec_id, :stdin, :stdout, :stderr

    def initialize(exec_id, mode)
      @exec_id = exec_id
      @exit_code = nil
      @completed = false
      
      @stdin = ModalWriteStream.new(ContainerProcessInputStream.new(exec_id))

      if mode == "text"
        @stdout = ModalReadStream.new(ContainerProcessOutputStream.new(exec_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDOUT, true))
        @stderr = ModalReadStream.new(ContainerProcessOutputStream.new(exec_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDERR, true))
      else
        @stdout = ModalReadStream.new(ContainerProcessOutputStream.new(exec_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDOUT, false))
        @stderr = ModalReadStream.new(ContainerProcessOutputStream.new(exec_id, Modal::Client::FileDescriptor::FILE_DESCRIPTOR_STDERR, false))
      end
    end

    def wait
      loop do
        request = Modal::Client::ContainerExecWaitRequest.new(
          exec_id: @exec_id,
          timeout: 55 # seconds
        )
        resp = Modal.client.call(:container_exec_wait, request)
        if resp.completed
          @completed = true
          @exit_code = resp.exit_code || 0
          return @exit_code
        end
        sleep(1) # Poll every second
      end
    end

    def poll
      return @exit_code if @completed

      request = Modal::Client::ContainerExecWaitRequest.new(
        exec_id: @exec_id,
        timeout: 1 # Short timeout for non-blocking behavior
      )
      resp = Modal.client.call(:container_exec_wait, request)
      if resp.completed
        @completed = true
        @exit_code = resp.exit_code || 0
        return @exit_code
      end
      nil # Still running
    end

    def returncode
      return @exit_code if @completed
      poll # Check current status
    end
  end

  class SandboxInputStream
    def initialize(sandbox_id)
      @sandbox_id = sandbox_id
      @index = 1
    end

    def write(chunk)
      request = Modal::Client::SandboxStdinWriteRequest.new(
        sandbox_id: @sandbox_id,
        input: chunk.bytes.pack("C*"), # Convert to bytes
        index: @index
      )
      Modal.client.call(:sandbox_stdin_write, request)
      @index += 1
    end

    def close
      request = Modal::Client::SandboxStdinWriteRequest.new(
        sandbox_id: @sandbox_id,
        index: @index,
        eof: true
      )
      Modal.client.call(:sandbox_stdin_write, request)
    end
  end

  class SandboxOutputStream
    def initialize(sandbox_id, file_descriptor)
      @sandbox_id = sandbox_id
      @file_descriptor = file_descriptor
      @last_entry_id = ""
      @data_collected = []
      @finished = false
    end

    def each
      return enum_for(:each) unless block_given?

      return if @finished

      # make one call and collect all data until EOF
      request = Modal::Client::SandboxGetLogsRequest.new(
        sandbox_id: @sandbox_id,
        file_descriptor: @file_descriptor,
        timeout: 10, # Give it more time to get all the data
        last_entry_id: @last_entry_id
      )

      begin
        resp = Modal.client.call(:sandbox_get_logs, request)

        # Process the entire streaming response
        resp.each do |batch|
          # Update last_entry_id
          if batch.respond_to?(:entry_id) && batch.entry_id && !batch.entry_id.empty?
            @last_entry_id = batch.entry_id
          end

          # Collect data from this batch
          if batch.respond_to?(:items) && batch.items
            batch.items.each do |item|
              if item.respond_to?(:data) && item.data && !item.data.empty?
                @data_collected << item.data
              end
            end
          end

          # Check for EOF
          if batch.respond_to?(:eof) && batch.eof
            @finished = true
            break
          end
        end
      rescue GRPC::BadStatus => e
        if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
          @finished = true
        else
          raise e
        end
      end

      # Yield all collected data
      @data_collected.each { |data| yield data }
    end
  end

  class ContainerProcessInputStream
    def initialize(exec_id)
      @exec_id = exec_id
      @message_index = 1
    end

    def write(chunk)
      request = Modal::Client::ContainerExecPutInputRequest.new(
        exec_id: @exec_id,
        input: Modal::Client::ContainerExecInput.new(
          message: chunk.bytes.pack("C*"), # Convert to bytes
          message_index: @message_index
        )
      )
      Modal.client.call(:container_exec_put_input, request)
      @message_index += 1
    end

    def close
      request = Modal::Client::ContainerExecPutInputRequest.new(
        exec_id: @exec_id,
        input: Modal::Client::ContainerExecInput.new(
          message_index: @message_index,
          eof: true
        )
      )
      Modal.client.call(:container_exec_put_input, request)
    end
  end

  class ContainerProcessOutputStream
    def initialize(exec_id, file_descriptor, decode_text)
      @exec_id = exec_id
      @file_descriptor = file_descriptor
      @decode_text = decode_text
      @last_batch_index = 0
      @finished = false
    end

    def each
      return enum_for(:each) unless block_given?
      return if @finished

      begin
        request = Modal::Client::ContainerExecGetOutputRequest.new(
          exec_id: @exec_id,
          file_descriptor: @file_descriptor,
          timeout: 55,
          get_raw_bytes: true,
          last_batch_index: @last_batch_index
        )

        stream = Modal.client.call(:container_exec_get_output, request)

        stream.each do |batch|
          @last_batch_index = batch.batch_index if batch.respond_to?(:batch_index)
          if batch.respond_to?(:items) && batch.items
            batch.items.each do |item|
              if item.message_bytes && !item.message_bytes.empty?
                yield item.message_bytes
              end
            end
          end

          if (batch.respond_to?(:has_exit_code) && batch.has_exit_code) || batch.items.empty?
            break
          end
        end
      rescue GRPC::BadStatus => e
        if e.code == GRPC::Core::StatusCodes::DEADLINE_EXCEEDED
        else
          raise e
        end
      end

      @finished = true
    end
  end
end
