# :nodoc:
# Batches the small writes made by JSON serializers without buffering an
# unbounded response. Once the limit is reached, subsequent writes go straight
# to the response IO. Flushing in an ensure preserves partial output when a
# serializer raises after it has already written bytes.
module ActionController::JSONBuffer
  LIMIT = 4096

  # Keep the original IO type for application-defined serializers. They may
  # intentionally specialize #to_json for HTTP::Server::Response.
  def self.serialize(output, value)
    value.to_json(output)
  end

  def self.serialize(output : IO, value : NamedTuple | Hash | Array)
    write(output) { |buffer| value.to_json(buffer) }
  end

  def self.write(output : IO, &)
    buffer = BoundedIO.new(output)
    begin
      yield buffer
    ensure
      buffer.flush
    end
  end

  private class BoundedIO < IO
    def initialize(@output : IO)
      @buffer = IO::Memory.new(128)
      @passthrough = false
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("JSON response buffer is write-only")
    end

    def write(slice : Bytes) : Nil
      if @passthrough
        @output.write(slice)
      elsif @buffer.size + slice.size <= LIMIT
        @buffer.write(slice)
      else
        flush
        @output.write(slice)
      end
    end

    def flush : Nil
      return if @passthrough

      @passthrough = true
      @output.write(@buffer.to_slice) if @buffer.size > 0
    end
  end
end
