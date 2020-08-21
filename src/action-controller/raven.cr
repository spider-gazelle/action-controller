require "http"
require "raven/integrations/http/handler"

require "./body_parser"
require "./support"

module Raven
  class ActionController::ErrorHandler
    include Raven::HTTPHandler

    CULPRIT_PATTERN_KEYS = %i(method path)

    getter filter : Array(String)

    def initialize(
      filter = nil,
      @culprit_pattern = "%{method} %{path}",
      @capture_data_for_methods = %w(POST PUT PATCH),
      @default_logger = "action_controller"
    )
      @filter = filter ? filter.to_a.map(&.to_s) : [] of String
    end

    def build_raven_culprit_context(context : HTTP::Server::Context)
      context.request
    end

    def build_raven_http_url(context : HTTP::Server::Context)
      File.join(context.request.host_with_port, context.request.path)
    end

    def build_raven_http_data(context : HTTP::Server::Context)
      http_data = ::Raven::ActionController.extract_params(context).to_h
      filter.each do |key|
        http_data[key] = "[FILTERED]" if http_data.has_key?(key)
      end
      http_data
    end

    def self.extract_params(context : HTTP::Server::Context) : HTTP::Params
      params = context.request.params

      # duplicate the query_params
      qparams = context.request.query_params
      qparams.each do |key, _|
        params.set_all(key, qparams.fetch_all(key).dup)
      end

      # Add route params to the HTTP params
      # giving preference to route params
      context.request.route_params.each do |key, value|
        values = params.fetch_all(key)
        values.unshift(URI.decode(value))
        params.set_all(key, values)
      end

      # Add form data to params, lowest preference
      ctype = ::ActionController::Support.content_type(context.request.headers)

      ::ActionController::BodyParser.extract_form_data(context.request, ctype, params) if ctype

      params
    end
  end
end
