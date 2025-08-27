module Modal
  class FileWatchEvent
    attr_reader :type, :paths
    
    def initialize(type:, paths:)
      @type = type
      @paths = Array(paths)
    end
    
    def to_s
      "FileWatchEvent(type: #{@type}, paths: #{@paths})"
    end
  end
  
  module FileWatchEventType
    CREATED = "created"
    MODIFIED = "modified" 
    DELETED = "deleted"
    MOVED = "moved"
    
    ALL = [CREATED, MODIFIED, DELETED, MOVED].freeze
  end
end