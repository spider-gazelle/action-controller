require "../action-controller"
require "hot_topic"

module ActionController
  class SpecHelper
    include Router

    getter route_handler = RouteHandler.new
    getter composition : Composition

    def initialize(@composition : Composition = Composition.default)
      @route_handler = composition.handler.route_handler
    end

    def hot_topic
      HotTopic.new(@route_handler)
    end

    def self.client
      ActionController::SpecHelper.new.hot_topic
    end

    # :nodoc:
    module ContextHelper
      macro included
        macro inherited
          # Simplify obtaining an instance of a controller class in specs
          def self.spec_instance(request : HTTP::Request = HTTP::Request.new("GET", "/"))
            response = HTTP::Server::Response.new(IO::Memory.new, request.version)
            context = HTTP::Server::Context.new request, response
            context.response.output = IO::Memory.new

            method = request.method
            req_path = request.path

            ActionController::SpecHelper.new.route_handler.search_route(method, req_path, context)
            self.new(context)
          end
        end
      end
    end
  end

  abstract class Base
    # extend the action controller classes with the `with_state` helper
    include SpecHelper::ContextHelper
  end
end

# Extend hot topic for establishing a websocket request
class HotTopic::Client(T) < HTTP::Client
  def establish_ws(uri : URI | String, headers = HTTP::Headers.new) : HTTP::WebSocket
    # build bi-directional io
    local_read, remote_write = IO.pipe
    remote_read, local_write = IO.pipe
    # the server signals EOF by closing only its write end, the pipe the client writes
    # into stays open so the client can still reply to a close frame
    local_io = IO::Stapled.new(local_read, local_write, sync_close: true)
    remote_io = IO::Stapled.new(remote_read, remote_write)

    begin
      random_key = Base64.strict_encode(StaticArray(UInt8, 16).new { rand(256).to_u8 })

      headers["Connection"] = "Upgrade"
      headers["Upgrade"] = "websocket"
      headers["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
      headers["Sec-WebSocket-Key"] = random_key

      case uri
      in URI
        if (user = uri.user) && (password = uri.password)
          headers["Authorization"] ||= "Basic #{Base64.strict_encode("#{user}:#{password}")}"
        end
        path = uri.request_target
      in String
        path = uri
      end

      handshake = HTTP::Request.new("GET", path, headers)
      response = HTTP::Server::Response.new(remote_io)
      context = HTTP::Server::Context.new(handshake, response)

      # emulate the upgrade request processing
      app_error = nil
      spawn do
        begin
          @app.call(context)
          if upgrade_handler = response.upgrade_handler
            upgrade_handler.call(remote_io)
          else
            # the handshake was rejected (e.g. by a filter), send the response
            # so the client isn't left waiting for one
            response.close
          end
        rescue error
          app_error = error
        ensure
          remote_write.close
        end
      end

      handshake_response = begin
        HTTP::Client::Response.from_io(local_io, ignore_body: true)
      rescue error : IO::Error
        # surface the application's exception, if that's why the connection closed
        if failure = app_error
          raise failure
        end
        raise error
      end
      unless handshake_response.status.switching_protocols?
        raise Socket::Error.new("Handshake got denied. Status code was #{handshake_response.status.code}.")
      end

      challenge_response = HTTP::WebSocket::Protocol.key_challenge(random_key)
      unless handshake_response.headers["Sec-WebSocket-Accept"]? == challenge_response
        raise Socket::Error.new("Handshake got denied. Server did not verify WebSocket challenge.")
      end
    rescue error
      local_io.close
      remote_read.close
      remote_write.close
      raise error
    end

    HTTP::WebSocket.new HTTP::WebSocket::Protocol.new(local_io, masked: true)
  end
end
