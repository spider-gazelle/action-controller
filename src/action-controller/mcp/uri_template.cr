require "uri"

module ActionController::MCPServer
  # the subset of [RFC 6570](https://www.rfc-editor.org/rfc/rfc6570) URI templates used by
  # resource templates: simple `{name}` expansions, which never span a `/`, and a trailing
  # form style query `{?name,other}`
  #
  # ```
  # template = URITemplate.new("app://widgets/{id}/logs{?seconds}")
  # template.match("app://widgets/12/logs?seconds=30") # => {"id" => "12", "seconds" => "30"}
  # ```
  class URITemplate
    getter template : String

    # the variables in the path, in order
    getter path_variables : Array(String) = [] of String

    # the variables of the query expansion
    getter query_variables : Array(String) = [] of String

    # raised when a template uses unsupported syntax
    class Error < ::ArgumentError
    end

    @pattern : Regex

    def initialize(@template : String)
      literal = template
      if query_start = template.index("{?")
        unless template.ends_with?('}') && template.index('}', query_start) == template.size - 1
          raise Error.new("#{template}: a {?query} expansion must end the template")
        end
        @query_variables = template[(query_start + 2)...-1].split(',').map { |name| variable_name(name) }
        literal = template[0, query_start]
      end

      pattern = String.build do |regex|
        regex << '^'
        remaining = literal
        while start = remaining.index('{')
          regex << Regex.escape(remaining[0, start])
          finish = remaining.index('}', start) || raise Error.new("#{template}: unterminated expression")
          @path_variables << variable_name(remaining[(start + 1)...finish])
          regex << "([^/?#]+)"
          remaining = remaining[(finish + 1)..]
        end
        raise Error.new("#{template}: unexpected }") if remaining.includes?('}')
        regex << Regex.escape(remaining)
        regex << '$'
      end
      @pattern = Regex.new(pattern)
    end

    # the variables of a matching URI, percent decoded, otherwise `nil`. Query params
    # that aren't template variables don't match
    def match(uri : String) : Hash(String, String)?
      path, _, query = uri.partition('?')
      return unless found = @pattern.match(path)

      variables = {} of String => String
      @path_variables.each_with_index do |name, index|
        variables[name] = URI.decode(found[index + 1])
      end
      return variables if query.empty?
      return if @query_variables.empty?

      URI::Params.parse(query).each do |name, value|
        return unless @query_variables.includes?(name)
        variables[name] = value
      end
      variables
    end

    # sorts templates so the most specific are matched first: those with fewer variables,
    # then longer literals
    def specificity : Tuple(Int32, Int32)
      {path_variables.size, -template.size}
    end

    private def variable_name(name : String) : String
      name = name.strip
      unless name.matches?(/\A[a-zA-Z0-9_]+\z/)
        raise Error.new("#{template}: unsupported expression {#{name}}, only {name} and a trailing {?name,other} are supported")
      end
      name
    end
  end
end
