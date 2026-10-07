require "./base"
require "digest/sha256"

# Selects controller subtrees and supplies a fresh HTTP handler for each application.
# Request controllers continue to be constructed with their request context.
class ActionController::Composition
  include Router
  include HTTP::Handler

  # :nodoc:
  ROOTS = [] of Nil

  # :nodoc:
  record Controller,
    name : String,
    ancestors : Array(String),
    base : String,
    catalog : String,
    routes : Array(Tuple(String, Symbol, Symbol, String)),
    internal_routes : Array(Tuple(String, Symbol, Symbol, String)),
    register : Proc(Composition, String, Nil),
    register_internal : Proc(Composition, String, Nil)

  # :nodoc:
  record Mount, owner : String, path : String, target : String

  # A controller exposed at a particular public base path.
  record Placement, controller : Controller, base : String do
    def path(original : String) : String
      Composition.join(base, Composition.relative(original, controller.base))
    end
  end

  getter placements : Array(Placement)
  getter? explicit : Bool

  # Defaults to automatic discovery. Configure once, before constructing servers.
  class_property default : Composition { new(configured_roots) }

  # :nodoc:
  def self.configured_roots : Array(String)?
    {% if ROOTS.empty? %}
      nil
    {% else %}
      [{% for root in ROOTS %}{{ root }}, {% end %}] of String
    {% end %}
  end

  def initialize(roots : Array(String)? = nil)
    @explicit = !roots.nil?
    controllers = self.class.controllers
    mounts = self.class.mounts
    names = controllers.map(&.name)
    roots ||= controllers.reject do |controller|
      controller.ancestors.any? { |ancestor| names.includes?(ancestor) } ||
        mounts.any? { |mount| controller.name == mount.target || controller.ancestors.includes?(mount.target) }
    end.map(&.name)
    @placements = [] of Placement
    roots.each { |root| expand(root, nil, controllers, mounts, [] of String) }
    validate_routes!
    @placements.each { |placement| placement.controller.register.call(self, placement.base) }
  end

  private def expand(root : String, public_base : String?, controllers : Array(Controller), mounts : Array(Mount), stack : Array(String)) : Nil
    if stack.includes?(root)
      raise ArgumentError.new("mount cycle: #{(stack + [root]).join(" -> ")}")
    end
    definition = controllers.find(&.name.==(root)) || raise ArgumentError.new("unknown application root #{root}")
    selected = controllers.select { |controller| controller.name == root || controller.ancestors.includes?(root) }
    selected.reject! do |controller|
      controller.name != root && mounts.any? do |mount|
        mount.target != root && (controller.name == mount.target || controller.ancestors.includes?(mount.target))
      end
    end
    selected.each do |controller|
      base = public_base ? self.class.join(public_base, self.class.relative(controller.base, definition.base)) : controller.base
      @placements << Placement.new(controller, base)
      mounts.select(&.owner.==(controller.name)).each do |mount|
        expand(mount.target, self.class.join(base, mount.path), controllers, mounts, stack + [root])
      end
    end
  end

  # A fresh handler, so independent servers never share a mutable `next` link.
  def handler : Composition
    Composition.new(placements.dup, explicit?)
  end

  # :nodoc:
  def initialize(@placements : Array(Placement), @explicit : Bool)
    validate_routes!
    @placements.each { |placement| placement.controller.register.call(self, placement.base) }
  end

  def call(context : HTTP::Server::Context) : Nil
    if action = route_handler.search_route(context.request.method, context.request.path, context)
      route_handler.process_request(context.request.method, context.request.path, context, action[0], action[1])
    else
      call_next(context)
    end
  end

  def routes : Array(Tuple(String, Symbol, Symbol, String))
    placements.flat_map do |placement|
      placement.controller.routes.map { |route| {route[0], route[1], route[2], placement.path(route[3])} }
    end
  end

  # Identifies the selected placements and their public route definitions.
  getter signature : String do
    Digest::SHA256.hexdigest(placements.map { |placement| {placement.controller.name, placement.base, placement.controller.routes, placement.controller.internal_routes, placement.controller.catalog}.to_json }.join("\n"))
  end

  # Builds a public URL outside a request. Specify mount_base for repeated mounts.
  def url_for(controller : Base.class, action : Symbol, mount_base : String? = nil, hash_parts : Hash((String | Symbol), (Bool | Int32 | Int64 | Float32 | Float64 | String | Symbol)?)? = nil, **tuple_parts) : String
    matches = placements.select { |placement| placement.controller.name == controller.name && (!mount_base || self.class.join("/", mount_base) == self.class.join("/", placement.base)) }
    raise InvalidRoute.new("select mount_base for #{controller.name}: expected one placement, found #{matches.size}") unless matches.size == 1
    placement = matches.first
    route = placement.controller.routes.find(&.[1].==(action)) || raise InvalidRoute.new("unknown action #{controller.name}##{action}")
    Support.build_route(placement.path(route[3]), hash_parts, **tuple_parts)
  end

  # :nodoc:
  def register_internal(router : Composition) : Nil
    placements.each { |placement| placement.controller.register_internal.call(router, placement.base) }
  end

  # :nodoc:
  def self.controllers : Array(Controller)
    {% begin %}
      [
        {% for klass in Base::CONTROLLER_BASES.keys %}
          Controller.new(
            {{ klass.stringify }},
            {{ Base::CONTROLLER_ANCESTORS[klass] }}.map(&.to_s),
            {{ klass }}.base_route,
            {% catalog = [] of Nil %}
            {% for _key, metadata in Route::Builder::OPENAPI_ROUTES %}
              {% catalog << metadata.stringify if metadata[:controller] == klass.stringify %}
            {% end %}
            {{ catalog.join("\n") }},
            {% if Base::CONCRETE_CONTROLLERS[klass] %}
              {{ klass }}.__route_list__,
              {{ klass }}.__internal_route_list__,
              ->(router : Composition, base : String) { {{ klass }}.__init_routes__(router, base) },
              ->(router : Composition, base : String) { {{ klass }}.__init_internal_routes__(router, base) },
            {% else %}
              ([] of Tuple(String, Symbol, Symbol, String)),
              ([] of Tuple(String, Symbol, Symbol, String)),
              ->(_router : Composition, _base : String) { nil },
              ->(_router : Composition, _base : String) { nil },
            {% end %}
          ),
        {% end %}
      ] of Controller
    {% end %}
  end

  # :nodoc:
  def self.mounts : Array(Mount)
    {% begin %}
      [
        {% for owner, mounts in Base::MOUNTS %}
          {% for mount in mounts %}
            {% target = mount[1].resolve %}
            {% raise "#{owner}: mount target #{target} must inherit ActionController::Base" unless target < ::ActionController::Base %}
            Mount.new({{ owner.stringify }}, {{ mount[0] }}, {{ target.name.stringify }}),
          {% end %}
        {% end %}
      ] of Mount
    {% end %}
  end

  # :nodoc:
  def self.join(base : String, path : String) : String
    "/" + (base + "/" + path).split('/').reject(&.empty?).join('/')
  end

  # :nodoc:
  def self.relative(path : String, base : String) : String
    path = join("/", path)
    base = join("/", base)
    return path if base == "/"
    return "/" if path == base
    return path[base.size..] if path.starts_with?(base + "/")
    path
  end

  # :nodoc:
  def self.pattern(path : String) : String
    join("/", path).split('/').map { |part| part.starts_with?(':') ? ":param" : part.starts_with?("*:") ? "*:param" : part }.join('/')
  end

  private def validate_routes! : Nil
    seen = {} of Tuple(String, String) => Tuple(String, Bool)
    placements.each do |placement|
      relocated = self.class.join("/", placement.base) != self.class.join("/", placement.controller.base)
      (placement.controller.routes + placement.controller.internal_routes).each do |original|
        route = {original[0], original[1], original[2], placement.path(original[3])}
        parameters = route[3].split('/').select { |part| part.starts_with?(':') || part.starts_with?("?:") || part.starts_with?("*:") }.map { |part| part.split(':', 2)[1] }
        if parameters.uniq.size != parameters.size
          raise ArgumentError.new("ambiguous path parameters in #{route[3]}")
        end
        required = original[3].split('/').select(&.starts_with?(':')).map { |part| part.split(':', 2)[1] }
        public_required = route[3].split('/').select(&.starts_with?(':')).map { |part| part.split(':', 2)[1] }
        missing = required - public_required
        unless missing.empty?
          raise ArgumentError.new("mount #{route[3]} removes required path parameters #{missing.join(", ")}")
        end
        method = route[2] == :ws ? "GET" : route[2].to_s.upcase
        method = "INTERNAL_#{method}" if placement.controller.internal_routes.includes?(original)
        Router::RouteHandler.optional_variants(route[3], glob: true).each do |(variant, _)|
          normalized = self.class.pattern(variant)
          methods = method == "GET" ? ["GET", "HEAD"] : [method]
          methods.each do |verb|
            key = {verb, normalized}
            owner = "#{route[0]}##{route[1]}"
            if previous = seen[key]?
              if explicit? || relocated || previous[1]
                raise ArgumentError.new("conflicting route #{verb} #{variant}: #{previous[0]} and #{owner}")
              end
            end
            seen[key] = {owner, relocated}
          end
        end
      end
    end
  end
end

abstract class ActionController::Base
  # Serves this controller and its descendants, passing route misses downstream.
  def self.handler : Composition
    Composition.new([name])
  end
end
