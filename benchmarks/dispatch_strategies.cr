require "json"

# Compile with -Ddispatch_large to compare 256 targets instead of 16.
{% if flag?(:dispatch_large) %}
  TARGETS = 256
{% else %}
  TARGETS = 16
{% end %}

module DispatchFunctions
  {% for index in 0...TARGETS %}
    # Controller dispatch bodies are large enough that an extra dispatcher cannot
    # reasonably inline them all. Avoid folding our tiny synthetic bodies into
    # a single arithmetic expression instead of measuring dispatch.
    @[NoInline]
    def self.{{ "action_#{index}".id }}(value : UInt64, head : Bool) : UInt64
      (value &* 1_664_525_u64) ^ {{ index + 1 }}.to_u64 ^ (head ? 1_u64 : 0_u64)
    end
  {% end %}

  def self.by_id(id : Int32, value : UInt64, head : Bool) : UInt64
    {% begin %}
    case id
    {% for index in 0...TARGETS %}
      when {{ index }} then {{ "action_#{index}".id }}(value, head)
    {% end %}
    else raise "invalid dispatch ID"
    end
    {% end %}
  end
end

abstract class CallableDispatch
  abstract def call(value : UInt64, head : Bool) : UInt64
end

{% for index in 0...TARGETS %}
  class {{ "Callable_#{index}".id }} < CallableDispatch
    def initialize(@bias : UInt64)
    end

    def call(value : UInt64, head : Bool) : UInt64
      DispatchFunctions.{{ "action_#{index}".id }}(value ^ @bias, head)
    end
  end
{% end %}

{% begin %}
plain = [] of Proc(UInt64, Bool, UInt64)
captured = [] of Proc(UInt64, Bool, UInt64)
objects = [] of CallableDispatch
{% for index in 0...TARGETS %}
  plain << ->DispatchFunctions.{{ "action_#{index}".id }}(UInt64, Bool)
  bias = ARGV.first?.try(&.to_u64) || 7_u64
  captured << ->(value : UInt64, head : Bool) { DispatchFunctions.{{ "action_#{index}".id }}(value ^ bias, head) }
  objects << {{ "Callable_#{index}".id }}.new(bias)
{% end %}

def measure(name : String, mixed : Bool, &)
  samples = [] of Float64
  checksums = [] of UInt64
  11.times do
    value = 12_345_u64
    start = Time.instant
    2_000_000.times do
      id = mixed ? (value >> 32).to_i! & (TARGETS - 1) : 0
      value = yield id, value, value.odd?
    end
    samples << (Time.instant - start).total_nanoseconds / 2_000_000
    checksums << value
  end
  # Preserve outputs so the optimizer cannot remove the work.
  puts({targets: TARGETS, strategy: name, mixed: mixed, ns: samples.sort[5], checksum: checksums.first}.to_json)
  checksums.first
end

bias = ARGV.first?.try(&.to_u64) || 7_u64
{false, true}.each do |mixed|
  expected = measure("plain Proc", mixed) { |id, value, head| plain[id].call(value ^ bias, head) }
  results = {
    measure("captured Proc", mixed) { |id, value, head| captured[id].call(value, head) },
    measure("callable object", mixed) { |id, value, head| objects[id].call(value, head) },
    measure("integer dispatch", mixed) { |id, value, head| DispatchFunctions.by_id(id, value ^ bias, head) },
  }
  raise "dispatch results differ" unless results.all? { |result| result == expected }
end
{% end %}
