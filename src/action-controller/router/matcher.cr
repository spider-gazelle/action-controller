require "lucky_router"

# Released LuckyRouter versions without snapshots retain the previous walk.
# The performance version owns both streaming and compiled route matching.
{% unless LuckyRouter::Matcher(Int32).has_method?(:compile) %}
  # :nodoc:
  # A lookup-only view. Retaining the source string keeps the bytes alive while
  # matching; captured values are copied into ordinary Strings before returning.
  struct ActionController::Router::PathSegment
    def initialize(@path : String, @offset : Int32, @length : Int32)
    end

    def to_slice : Bytes
      @path.to_slice[@offset, @length]
    end

    def ==(other : PathSegment) : Bool
      to_slice == other.to_slice
    end

    def ==(other : String) : Bool
      to_slice == other.to_slice
    end

    def hash(hasher)
      hasher.bytes(to_slice)
    end

    def value : String
      @path.byte_slice(@offset, @length)
    end
  end

  class String
    # :nodoc:
    # Hash(String, ...) compares its stored key with the lookup key. This overload
    # enables a byte view to look up a String key without allocating a substring.
    def ==(other : ActionController::Router::PathSegment) : Bool
      other == self
    end
  end

  # :nodoc:
  class LuckyRouter::Fragment(T)
    # Reuse the registered trie, its method payloads and dynamic branch order.
    # Captures are materialized only after a complete route has matched.
    def action_controller_match(path : String, offset : Int32, method : String) : Match(T)?
      return match_for_method(method) if offset >= path.bytesize
      bytes = path.to_slice
      index = offset
      while index < bytes.size && bytes[index] != '/'.ord
        index += 1
      end
      part = ActionController::Router::PathSegment.new(path, offset, index - offset)
      following = index + 1

      if static_child = static_parts[part]?
        if match = static_child.action_controller_match(path, following, method)
          return match
        end
      end
      dynamic_parts.each do |dynamic_child|
        if match = dynamic_child.action_controller_match(path, following, method)
          match.params[dynamic_child.path_part.name] = part.value
          return match
        end
      end
      if glob = glob_part
        if match = glob.match_for_method(method)
          # PathReader omits the final empty segment, so a glob drops exactly one
          # trailing slash while preserving empty segments inside its value.
          length = path.bytesize - offset - (path.ends_with?('/') ? 1 : 0)
          match.params[glob.path_part.name] = path.byte_slice(offset, length)
          return match
        end
      end
      nil
    end
  end
{% end %}

# :nodoc:
class ActionController::Router::Matcher(T) < LuckyRouter::Matcher(T)
  {% unless LuckyRouter::Matcher(Int32).has_method?(:compile) %}
    def match(method : String, path : String) : LuckyRouter::Match(T)?
      # The existing decoder retains authority over escaped paths. All route
      # registration and validation also stay with LuckyRouter.
      return super if path.includes?('%')

      root.action_controller_match(path, 0, method)
    end
  {% end %}
end
