# encoding: UTF-8
require 'socket' unless defined?(Socket)
require 'yajl' unless defined?(Yajl::Parser)
require 'uri' unless defined?(URI)
require 'openssl' unless defined?(OpenSSL)

module Yajl
  # This module is for making HTTP requests to which the response bodies (and possibly requests in the near future)
  # are streamed directly into Yajl.
  class HttpStream

    # This Exception is thrown when an HTTP response isn't in ALLOWED_MIME_TYPES
    # and therefore cannot be parsed.
    class InvalidContentType < Exception; end
    class HttpError < StandardError

      attr_reader :message, :headers

      def initialize(message, headers)
        @message = message
        @headers = headers
      end
    end

    # The mime-type we expect the response to be. If it's anything else, we can't parse it
    # and an InvalidContentType is raised.
    ALLOWED_MIME_TYPES = ["application/json", "text/plain"]

    # Makes a basic HTTP GET request to the URI provided
    def self.get(uri, opts = {}, &block)
      request("GET", uri, opts, &block)
    end

    # Makes a basic HTTP GET request to the URI provided allowing the user to terminate the connection
    def get(uri, opts = {}, &block)
      initialize_socket(uri, opts)
      HttpStream::get(uri, opts, &block)
    rescue IOError => e
      raise e unless @intentional_termination
    end

    # Makes a basic HTTP POST request to the URI provided
    def self.post(uri, body, opts = {}, &block)
      request("POST", uri, opts.merge({:body => body}), &block)
    end

    # Makes a basic HTTP POST request to the URI provided allowing the user to terminate the connection
    def post(uri, body, opts = {}, &block)
      initialize_socket(uri, opts)
      HttpStream::post(uri, body, opts, &block)
    rescue IOError => e
      raise e unless @intentional_termination
    end

    # Makes a basic HTTP PUT request to the URI provided
    def self.put(uri, body, opts = {}, &block)
      request("PUT", uri, opts.merge({:body => body}), &block)
    end

    # Makes a basic HTTP PUT request to the URI provided allowing the user to terminate the connection
    def put(uri, body, opts = {}, &block)
      initialize_socket(uri, opts)
      HttpStream::put(uri, body, opts, &block)
    rescue IOError => e
      raise e unless @intentional_termination
    end

    # Makes a basic HTTP DELETE request to the URI provided
    def self.delete(uri, opts = {}, &block)
      request("DELETE", uri, opts, &block)
    end

    # Makes a basic HTTP DELETE request to the URI provided allowing the user to terminate the connection
    def delete(uri, opts = {}, &block)
      initialize_socket(uri, opts)
      HttpStream::delete(uri, opts, &block)
    rescue IOError => e
      raise e unless @intentional_termination
    end

    # Terminate a running HTTPStream instance
    def terminate
      @intentional_termination = true
      @socket.close
    end

    protected
      def self.request(method, uri, opts = {}, &block)
        if uri.is_a?(String)
          uri = URI.parse(uri)
        end

        user_agent = opts.has_key?('User-Agent') ? opts.delete(['User-Agent']) : "Yajl::HttpStream #{Yajl::VERSION}"
        if method == "POST" || method == "PUT"
          content_type = opts.has_key?('Content-Type') ? opts.delete(['Content-Type']) : "application/x-www-form-urlencoded"
          body = opts.delete(:body)
          if body.is_a?(Hash)
            body = body.keys.collect {|param| "#{URI.escape(param.to_s)}=#{URI.escape(body[param].to_s)}"}.join('&')
          end
        end

        if opts.has_key?(:socket)
          socket = opts.delete(:socket)
        else
          sock = TCPSocket.new(uri.host, uri.port)
      		if uri.port == 443
        		ssl_context = OpenSSL::SSL::SSLContext.new
        		socket = OpenSSL::SSL::SSLSocket.new(sock, ssl_context)
        		socket.sync_close = true
        		socket.connect
      		else
        		socket = sock
      		end
      	end

        request = "#{method} #{uri.path}#{uri.query ? "?"+uri.query : nil} HTTP/1.1\r\n"
        request << "Host: #{uri.host}\r\n"
        request << "Authorization: Basic #{[uri.userinfo].pack('m').strip!}\r\n" unless uri.userinfo.nil?
        request << "User-Agent: #{user_agent}\r\n"
        request << "Accept: */*\r\n"
        if method == "POST" || method == "PUT"
          request << "Content-Length: #{body.length}\r\n"
          request << "Content-Type: #{content_type}\r\n"
        end
        encodings = []
        encodings << "bzip2" if defined?(Yajl::Bzip2)
        encodings << "gzip" if defined?(Yajl::Gzip)
        encodings << "deflate" if defined?(Yajl::Deflate)
        request << "Accept-Encoding: #{encodings.join(',')}\r\n" if encodings.any?
        request << "Accept-Charset: utf-8\r\n\r\n"
        if method == "POST" || method == "PUT"
          request << body
        end
        socket.write(request)
        response_head = {}
        response_head[:headers] = {}

        socket.each_line do |line|
          if line == "\r\n" # end of the headers
            break
          else
            header = line.split(": ")
            if header.size == 1
              header = header[0].split(" ")
              response_head[:version] = header[0]
              response_head[:code] = header[1].to_i
              response_head[:msg] = header[2]
              # this is the response code line
            else
              response_head[:headers][header[0]] = header[1].strip
            end
          end
        end

        if (response_head[:code] != 200)
          raise HttpError.new("Code 200 expected got #{response_head[:code]}", response_head[:headers])
        end

        parser = Yajl::Parser.new(opts)
        parser.on_parse_complete = block if block_given?
        if response_head[:headers]["Transfer-Encoding"] == 'chunked'
          if block_given?
            chunkLeft = 0
            while !socket.eof? && (line = socket.gets)
              break if line.match /0.*?\r\n/
              next if line == "\r\n"
              size = line.hex
              json = socket.read(size)
              next if json.nil?
              chunkLeft = size-json.size
              if chunkLeft == 0
                parser << json
              else
                # received only part of the chunk, grab the rest
                parser << socket.read(chunkLeft)
              end
            end
          else
            raise Exception, "Chunked responses detected, but no block given to handle the chunks."
          end
        else
          content_type = response_head[:headers]["Content-Type"].split(';')
          content_type = content_type.first
          if ALLOWED_MIME_TYPES.include?(content_type)
            case response_head[:headers]["Content-Encoding"]
            when "gzip"
              return Yajl::Gzip::StreamReader.parse(socket, opts, &block)
            when "deflate"
              return Yajl::Deflate::StreamReader.parse(socket, opts.merge({:deflate_options => -Zlib::MAX_WBITS}), &block)
            when "bzip2"
              return Yajl::Bzip2::StreamReader.parse(socket, opts, &block)
            else
              return parser.parse(socket)
            end
          else
            raise InvalidContentType, "The response MIME type #{content_type}"
          end
        end
      ensure
        socket.close if !socket.nil? and !socket.closed?
      end

  private
    # Initialize socket and add it to the opts
    def initialize_socket(uri, opts = {})
      sock = TCPSocket.new(uri.host, uri.port)
      if uri.port == 443
        ssl_context = OpenSSL::SSL::SSLContext.new
        @socket = OpenSSL::SSL::SSLSocket.new(sock, ssl_context)
        @socket.sync_close = true
        @socket.connect
      else
        @socket = sock
      end
      opts.merge!({:socket => @socket})
      @intentional_termination = false
    end
  end
end
