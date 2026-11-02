# :nodoc:
# Batches the small writes made by JSON serializers without buffering an
# unbounded response. Once the limit is reached, subsequent writes go straight
# to the response IO. Flushing in an ensure preserves partial output when a
# serializer raises after it has already written bytes.
module ActionController::JSONBuffer
  LIMIT = 4096

  # Output that isn't an IO is handed to the value unchanged.
  def self.serialize(output, value)
    value.to_json(output)
  end

  # Buffers the value unless one of the types it can hold at runtime defines a
  # `#to_json` overload that may want the original IO, such as one restricted
  # to HTTP::Server::Response. Buffering lets JSON::Builder#end_document flush
  # into the buffer instead of the response, so a small body is sent with a
  # Content-Length rather than committing the response to chunked encoding.
  #
  # The check runs at compile time and fails closed: subclasses and module
  # includers are considered (the value may be any of them), and any argument
  # restriction other than IO or JSON::Builder keeps the original IO. Containers
  # need no special handling, they hand their elements a JSON::Builder.
  def self.serialize(output : IO, value : T) forall T
    {% begin %}
      {% types = T.union? ? T.union_types : [T] %}
      {% for type in types %}
        {% for runtime_type in type.all_subclasses %}
          {% types << runtime_type unless types.includes?(runtime_type) %}
        {% end %}
        {% if type.module? %}
          {% for includer in type.includers %}
            {% types << includer unless types.includes?(includer) %}
          {% end %}
        {% end %}
      {% end %}
      {% specialized = types.any? do |type|
           ([type] + type.ancestors).any? do |owner|
             owner.methods.any? do |method|
               restriction = method.name.stringify == "to_json" && !method.args.empty? && method.args[0].restriction
               resolved = restriction.is_a?(Path) && restriction.resolve?
               restriction && resolved != ::IO && resolved != ::JSON::Builder
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
