require "net/http"
require "uri"
require "digest"

module Modal
  module BlobUtils
    MAX_OBJECT_SIZE_BYTES = 2 * 1024 * 1024 # 2 MiB
    
    def self.blob_download(blob_id, client_stub)
      request = Modal::Client::BlobGetRequest.new(blob_id: blob_id)
      resp = client_stub.call(:blob_get, request)
      
      if resp.download_url && !resp.download_url.empty?
        download_from_url(resp.download_url)
      else
        raise Modal::BlobDownloadError.new("No download URL provided for blob #{blob_id}")
      end
    end
    
    def self.blob_upload(data, client_stub)
      content_md5 = Digest::MD5.base64digest(data)
      content_sha256 = Digest::SHA256.base64digest(data)
      content_length = data.bytesize

      request = Modal::Client::BlobCreateRequest.new(
        content_md5: content_md5,
        content_sha256_base64: content_sha256,
        content_length: content_length
      )
      resp = client_stub.call(:blob_create, request)

      if resp.multipart
        raise "Blob size exceeds multipart upload threshold, unsupported by this SDK version"
      elsif resp.upload_url
        upload_to_url(resp.upload_url, data, content_md5)
        resp.blob_id
      else
        raise Modal::BlobUploadError.new("Missing upload URL in BlobCreate response")
      end
    end
    
    private
    
    def self.download_from_url(download_url)
      uri = URI.parse(download_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      
      req = Net::HTTP::Get.new(uri.request_uri)
      resp = http.request(req)
      
      unless resp.code.to_i >= 200 && resp.code.to_i < 300
        raise Modal::BlobDownloadError.new("Failed blob download: #{resp.message}")
      end
      
      resp.body
    end
    
    def self.upload_to_url(upload_url, data, content_md5)
      uri = URI.parse(upload_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      req = Net::HTTP::Put.new(uri.request_uri)
      req["Content-Type"] = "application/octet-stream"
      req["Content-MD5"] = content_md5
      req.body = data

      resp = http.request(req)

      unless resp.code.to_i >= 200 && resp.code.to_i < 300
        raise Modal::BlobUploadError.new("Failed blob upload: #{resp.message}")
      end
    end
  end
  
  class BlobDownloadError < StandardError; end
  class BlobUploadError < StandardError; end
end