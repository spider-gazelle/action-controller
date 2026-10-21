# :nodoc:
# Batches the small writes made by JSON serializers without buffering an
# unbounded response. Once the limit is reached, subsequent writes go straight
# to the response IO. Flushing in an ensure preserves partial output when a
# serializer raises after it has already written bytes.
module ActionController::JSONBuffer
  LIMIT = 4096

  def self.serialize(output, value)
    value.to_json(output)
  end

  # Buffers any value that serializes through `#to_json(IO)`. A type that
  # specializes `#to_json` for a narrower IO, such as HTTP::Server::Response,
  # keeps the original IO. Containers need no check: they hand their
  # elements a JSON::Builder, never the IO.
  def self.serialize(output : IO, value : T) forall T
    {% begin %}
      {% types = T.union? ? T.union_types : [T] %}
      {% specialized = types.any? do |type|
           ([type] + type.ancestors).any? do |owner|
             owner.methods.any? do |method|
               restriction = method.args.size == 1 && method.args[0].restriction
               method.name == "to_json" && restriction.is_a?(Path) &&
                 (resolved = restriction.resolve?) && resolved != ::IO && resolved < ::IO
             end
           end
         end %}
      {% if specialized %}
        value.to_json(output)
      {% else %}
        write(output) { |buffer| value.to_json(buffer) }
      {% end %}
    {% end %}
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
