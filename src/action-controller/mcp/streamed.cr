require "base64"
require "http/client/response"

module ActionController::MCPServer
  # :nodoc:
  # writes the bytes as the contents of a JSON string, escaping as required. Multi-byte
  # characters split across writes are passed through unchanged, so chunking is safe
  class JSONEscaper < IO
    def initialize(@io : IO)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("write only")
    end

    def write(slice : Bytes) : Nil
      start = 0
      slice.each_with_index do |byte, index|
        escaped = case byte
                  when '"'.ord  then "\\\""
                  when '\\'.ord then "\\\\"
                  when '\n'.ord then "\\n"
                  when '\r'.ord then "\\r"
                  when '\t'.ord then "\\t"
                  when .< 0x20  then "\\u%04x" % byte
                  end
        next unless escaped
        @io.write(slice[start, index - start]) if index > start
        @io << escaped
        start = index + 1
      end
      @io.write(slice[start..]) if start < slice.size
    end

    def flush : Nil
      @io.flush
    end
  end

  # :nodoc:
  # the response of a long running route, written to a temporary file. Writes past the
  # limit are dropped and the request context marked full, so the route can stop
  class Spool < IO
    getter file : File
    getter? overflowed : Bool = false

    @written = 0_i64

    def initialize(@limit : Int64?, @context : RequestContext?)
      @file = File.tempfile("mcp-response")
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("write only")
    end

    def write(slice : Bytes) : Nil
      return if @overflowed
      if (limit = @limit) && @written + slice.size > limit
        @overflowed = true
        @context.try &.full = true
        return
      end
      @written += slice.size
      @file.write(slice)
    end

    def flush : Nil
      @file.flush
    end

    def delete : Nil
      @file.close rescue nil
      @file.delete rescue nil
    end
  end

  # :nodoc:
  # a route response spooled to disk, `max_bytes` limits the body
  class Spooled
    getter status : HTTP::Status
    getter headers : HTTP::Headers

    def initialize(@spool : Spool, @max_bytes : Int64?)
      status = HTTP::Status::INTERNAL_SERVER_ERROR
      headers = HTTP::Headers.new
      Spooled.read(@spool.file) do |response|
        status = response.status
        headers = response.headers
      end
      @status = status
      @headers = headers
    end

    def mime_type : String?
      @headers["Content-Type"]?.try { |value| MIME::MediaType.parse?(value).try(&.media_type) }
    end

    # the body as a string, for error responses
    def body(limit : Int32 = 4096) : String
      text = ""
      read do |response|
        if body = response.body_io?
          buffer = Bytes.new(limit)
          text = String.new(buffer[0, body.read(buffer)])
        end
      end
      text
    rescue IO::Error
      ""
    end

    # copies the body, returning true if it was truncated: by `max_bytes`, or as the spool
    # overflowed
    def copy_body(output : IO) : Bool
      truncated = @spool.overflowed?
      read do |response|
        next unless body = response.body_io?
        buffer = Bytes.new(16 * 1024)
        copied = 0_i64
        loop do
          count = begin
            body.read(buffer)
          rescue IO::Error
            # an overflowed spool ends mid response
            truncated = true
            break
          end
          break if count.zero?
          if (limit = @max_bytes) && copied + count > limit
            output.write(buffer[0, limit - copied])
            truncated = true
            break
          end
          output.write(buffer[0, count])
          copied += count
        end
      end
      truncated
    end

    # copies the body as base64, returning true if it was truncated
    def copy_body_base64(output : IO) : Bool
      encoder = Base64Writer.new(output)
      truncated = copy_body(encoder)
      encoder.finish
      truncated
    end

    def close : Nil
      @spool.delete
    end

    private def read(&)
      Spooled.read(@spool.file) { |response| yield response }
    end

    protected def self.read(file : File, &)
      file.rewind
      HTTP::Client::Response.from_io(file, decompress: false) { |response| yield response }
    end
  end

  # :nodoc:
  # base64 encodes a stream, in whole groups of 3 bytes until `finish`
  class Base64Writer < IO
    @pending = IO::Memory.new

    def initialize(@io : IO)
    end

    def read(slice : Bytes) : NoReturn
      raise IO::Error.new("write only")
    end

    def write(slice : Bytes) : Nil
      @pending.write(slice)
      whole = @pending.size - @pending.size % 3
      return if whole.zero?
      bytes = @pending.to_slice
      Base64.strict_encode(bytes[0, whole], @io)
      rest = bytes[whole..].dup
      @pending.clear
      @pending.write(rest)
    end

    def finish : Nil
      Base64.strict_encode(@pending.to_slice, @io) unless @pending.empty?
      @pending.clear
    end
  end

  # a result streamed from a spooled response, rather than built in memory
  abstract class StreamedResult
    def initialize(@spooled : Spooled)
    end

    # writes the result object's fields, without the enclosing braces
    abstract def write_fields(io : IO) : Nil

    # deletes the spooled response
    def close : Nil
      @spooled.close
    end
  end

  # :nodoc:
  # a tool result, the response envelope as text
  class StreamedToolResult < StreamedResult
    def write_fields(io : IO) : Nil
      spooled = @spooled
      status = spooled.status
      error = !status.success? && !status.redirection?
      headers = MCPServer.visible_headers(spooled.headers)

      io << %("content":[{"type":"text","text":")
      text = JSONEscaper.new(io)
      text << %({"status":) << status.code
      text << %(,"headers":) << headers.to_json unless headers.empty?
      text << %(,"body":")
      truncated = spooled.copy_body(JSONEscaper.new(text))
      text << '"'
      text << %(,"truncated":true) if truncated
      text << '}'
      io << %("}],"isError":) << error
    end
  end

  # :nodoc:
  # a resource read, the body as the resource contents
  class StreamedResourceResult < StreamedResult
    def initialize(spooled : Spooled, @uri : String, @mime_type : String?)
      super(spooled)
    end

    def write_fields(io : IO) : Nil
      io << %("contents":[{"uri":) << @uri.to_json
      io << %(,"mimeType":) << @mime_type.to_json if @mime_type
      truncated = if MCPServer.text_mime_type?(@mime_type)
                    io << %(,"text":")
                    @spooled.copy_body(JSONEscaper.new(io)).tap { io << '"' }
                  else
                    io << %(,"blob":")
                    @spooled.copy_body_base64(io).tap { io << '"' }
                  end
      io << %(,"_meta":{"truncated":true}) if truncated
      io << "}]"
    end
  end

  # :nodoc:
  # resource contents of this type are text, everything else is a base64 blob
  def text_mime_type?(mime_type : String?) : Bool
    return true unless mime_type
    mime_type.starts_with?("text/") || {"json", "xml", "yaml", "javascript", "csv"}.any? { |kind| mime_type.includes?(kind) }
  end
end
