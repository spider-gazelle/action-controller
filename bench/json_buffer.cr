# Run with: crystal build --release -o bench/bin/json-buffer bench/json_buffer.cr
require "../src/action-controller/json_buffer"
require "json"

iterations = (ARGV[0]?.try(&.to_i) || 10_000)
raise "iterations must be positive" unless iterations > 0

[32, 4096, 100_000].each do |size|
  value = {data: "x" * size}
  expected = value.to_json
  {"direct" => false, "bounded" => true}.each do |label, buffered|
    100.times do
      io = IO::Memory.new
      if buffered
        ActionController::JSONBuffer.write(io) { |output| value.to_json(output) }
      else
        value.to_json(io)
      end
    end
    GC.collect
    before = GC.stats
    checksum = 0
    started = Time.instant
    iterations.times do
      io = IO::Memory.new
      if buffered
        ActionController::JSONBuffer.write(io) { |output| value.to_json(output) }
      else
        value.to_json(io)
      end
      raise "serialization differs" unless io.to_s == expected
      checksum += io.size
    end
    elapsed = Time.instant - started
    after = GC.stats
    ns_per_op = elapsed.total_nanoseconds / iterations
    bytes_per_op = (after.total_bytes - before.total_bytes) / iterations
    puts "#{size} bytes #{label.ljust(7)} #{ns_per_op.round(1)} ns/op #{bytes_per_op.round(1)} B/op checksum=#{checksum}"
  end
end
