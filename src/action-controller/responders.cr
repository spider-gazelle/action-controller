require "json"
require "yaml"

module ActionController::Responders
  STATUS_CODES = {
    # 1xx informational
    continue:            100,
    switching_protocols: 101,
    processing:          102,

    # 2xx success
    ok:                            200,
    created:                       201,
    accepted:                      202,
    non_authoritative_information: 203,
    no_content:                    204,
    reset_content:                 205,
    partial_content:               206,
    multi_status:                  207,
    already_reported:              208,
    im_used:                       226,

    # 4xx client error
    bad_request:                     400,
    unauthorized:                    401,
    payment_required:                402,
    forbidden:                       403,
    not_found:                       404,
    method_not_allowed:              405,
    not_acceptable:                  406,
    proxy_authentication_required:   407,
    request_timeout:                 408,
    conflict:                        409,
    gone:                            410,
    length_required:                 411,
    precondition_failed:             412,
    payload_too_large:               413,
    uri_too_long:                    414,
    unsupported_media_type:          415,
    range_not_satisfiable:           416,
    expectation_failed:              417,
    misdirected_request:             421,
    unprocessable_entity:            422,
    locked:                          423,
    failed_dependency:               424,
    upgrade_required:                426,
    precondition_required:           428,
    too_many_requests:               429,
    request_header_fields_too_large: 431,
    unavailable_for_legal_reasons:   451,

    # 5xx server error
    internal_server_error:           500,
    not_implemented:                 501,
    bad_gateway:                     502,
    service_unavailable:             503,
    gateway_timeout:                 504,
    http_version_not_supported:      505,
    variant_also_negotiates:         506,
    insufficient_storage:            507,
    loop_detected:                   508,
    not_extended:                    510,
    network_authentication_required: 511,
  }

  REDIRECTION_CODES = {
    # 3xx redirection
    multiple_choices:   300,
    moved_permanently:  301,
    found:              302,
    see_other:          303,
    not_modified:       304,
    use_proxy:          305,
    temporary_redirect: 307,
    permanent_redirect: 308,
  }

  MIME_TYPES = {
    binary: "application/octet-stream",
    json:   "application/json",
    xml:    "application/xml",
    text:   "text/plain",
    html:   "text/html",
    yaml:   "text/yaml",
  }

  macro render(status = :ok, head = Nop, json = Nop, yaml = Nop, xml = Nop, html = Nop, text = Nop, binary = Nop, template = Nop, partial = Nop, layout = nil)
    {% if [head, json, xml, html, yaml, text, binary, template, partial].all? &.is_a? Path %}
      {{ raise "Render must be called with one of json, xml, html, yaml, text, binary, template, partial" }}
    {% end %}

    %response = @context.response

    {% if status.is_a?(SymbolLiteral) %}
      %response.status_code = {{STATUS_CODES[status]}}
    {% else %}
      %response.status_code = ({{status}}).to_i
    {% end %}

    %ctype = %response.headers["Content-Type"]?

    {% if !json.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:json]}} unless %ctype
      {% if json.is_a?(String) %}
        {{json}}.to_s(%response) unless @__head_request__
      {% else %}
        ({{json}}).to_json(%response) unless @__head_request__
      {% end %}
    {% end %}

    {% if !yaml.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:yaml]}} unless %ctype
      {% if yaml.is_a?(String) %}
        {{yaml}}.to_s(%response) unless @__head_request__
      {% else %}
        ({{yaml}}).to_yaml(%response) unless @__head_request__
      {% end %}
    {% end %}

    {% if !xml.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:xml]}} unless %ctype
      {{xml}}.to_s(%response) unless @__head_request__
    {% end %}

    {% if !html.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:html]}} unless %ctype
      {{html}}.to_s(%response) unless @__head_request__
    {% end %}

    {% if !text.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:text]}} unless %ctype
      {{text}}.to_s(%response) unless @__head_request__
    {% end %}

    {% if !binary.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:binary]}} unless %ctype
      {{binary}}.to_s(%response) unless @__head_request__
    {% end %}

    {% if !template.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:html]}} unless %ctype
      {% if layout %}
        template({{template}}, layout: {{layout}}, io: %response) unless @__head_request__
      {% else %}
        template({{template}}, io: %response) unless @__head_request__
      {% end %}
    {% end %}

    {% if !partial.is_a? Path %}
      %response.content_type = {{MIME_TYPES[:html]}} unless %ctype
      template(partial: {{partial}}, io: %response) unless @__head_request__
    {% end %}

    @render_called = true
    return
  end

  macro head(status)
    render({{status}}, true)
  end

  macro redirect_to(path, status = :found)
    %response = @context.response
    %response.status_code = {{REDIRECTION_CODES[status] || status}}
    %response.headers["Location"] = {{path}}
    @render_called = true
    return
  end

  macro respond_with(status = :ok, &block)
    %resp = SelectResponse.new(response, accepts_formats, @__head_request__)
    %resp.responses do
      {{block.body}}
    end
    {% if status != :ok || status != 200 %}
      %response = @context.response
      {% if status.is_a?(SymbolLiteral) %}
        %response.status_code = {{STATUS_CODES[status]}}
      {% else %}
        %response.status_code = ({{status}}).to_i
      {% end %}
    {% end %}
    %resp.build_response
    @render_called = true
    return
  end

  ACCEPT_SEPARATOR_REGEX = /,\s*/

  # Extracts the mime types from the Accept header
  def accepts_formats
    accept = request.headers["Accept"]?
    if accept && !accept.empty?
      accepts = accept.split(";").first?.try(&.split(ACCEPT_SEPARATOR_REGEX))
      return accepts if accepts && accepts.any?
    end
    [] of String
  end

  # Helper class for selecting the response to render / execute
  class SelectResponse
    def initialize(@response : HTTP::Server::Response, formats, @head_request : Bool)
      @accepts = SelectResponse.accepts(formats)
      @options = {} of Symbol => Proc(IO, Nil)
    end

    @accepts : Hash(Symbol, String)
    getter options

    # Build a list of possible responses to the request
    def responses
      with self yield
    end

    macro html(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:html] = ->(io : IO){ ({{obj}}).to_s(io) }
      {% else %}
        options[:html] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    macro xml(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:xml] = ->(io : IO){ ({{obj}}).to_s(io) }
      {% else %}
        options[:xml] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    macro json(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:json] = ->(io : IO){
          output = {{obj}}
          {% if obj.is_a?(String) %}
            output.to_s(io)
          {% else %}
            output.to_json(io)
          {% end %}
        }
      {% else %}
        options[:json] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    macro yaml(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:yaml] = ->(io : IO){
          output = {{obj}}
          {% if obj.is_a?(String) %}
            output.to_s(io)
          {% else %}
            output.to_yaml(io)
          {% end %}
        }
      {% else %}
        options[:yaml] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    macro text(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:text] = ->(io : IO){ ({{obj}}).to_s(io) }
      {% else %}
        options[:text] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    macro binary(obj = nil, &block : IO -> Nil)
      {% if block.is_a?(Nop) %}
        options[:binary] = ->(io : IO){ ({{obj}}).to_s(io) }
      {% else %}
        options[:binary] = ->(io : IO){
          ({{ block.body }}).to_s(io)
        }
      {% end %}
    end

    # Respond appropriately
    def build_response
      found = nil

      # Search for the first acceptable format
      if @accepts.any?
        @accepts.each do |response_format, mime|
          option = @options[response_format]?
          if option
            @response.content_type = mime
            found = option
            break
          end
        end

        if found
          found.call(@response) unless @head_request
        else
          @response.status_code = 406 # not acceptable
        end
      else
        # If no format requested then default to the first format specified
        opt = @options.first
        format = opt[0]
        @response.content_type = MIME_TYPES[format]
        opt[1].call(@response) unless @head_request
      end
    end

    ACCEPTED_FORMATS = {
      "text/html":                :html,
      "application/xml":          :xml,
      "text/xml":                 :xml,
      "application/json":         :json,
      "text/plain":               :text,
      "application/octet-stream": :binary,
      "text/yaml":                :yaml,
      "text/x-yaml":              :yaml,
      "application/yaml":         :yaml,
      "application/x-yaml":       :yaml,
    }

    # Creates an ordered list of supported formats with requested mime types
    def self.accepts(accepts_formats)
      formats = {} of Symbol => String
      accepts_formats.each do |format|
        data_type = ACCEPTED_FORMATS[format]?
        if data_type && formats[data_type]?.nil?
          formats[data_type] = format
        end
      end
      formats
    end
  end
end
