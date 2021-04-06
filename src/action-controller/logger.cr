require "log"

module ActionController
  Log = ::Log.for("action-controller")

  def self.default_formatter
    ::Log::Formatter.new do |entry, io|
      label = entry.severity.label
      timestamp = entry.timestamp
      context = entry.context
      data = entry.data
      io << String.build do |str|
        str << "level="
        # Left justify by length of "NOTICE", the longest `Log::Severity`
        label.ljust(str, 6)
        str << " time="
        timestamp.to_rfc3339(str)
        str << " source=" << entry.source unless entry.source.empty?
        str << " message=\"" << entry.message << '"' unless entry.message.empty?

        # Add context tags
        {context, data}.each &.each do |k, v|
          str << " " << k << "=" << v
        end

        if exception = entry.exception
          str << "\n"
          exception.inspect_with_backtrace(str)
        end
      end
    end
  end

  def self.log_metadata_to_raw(metadata)
    value = metadata.raw
    case value
    in Array(::Log::Metadata::Value)
      value.map(&.to_s)
    in Hash(String, ::Log::Metadata::Value)
      value.transform_values(&.to_s)
    in Bool, Float32, Float64, Int32, Int64, String, Time, Nil
      metadata.raw.as(Bool | Float32 | Float64 | Int32 | Int64 | String | Time | Nil)
    end
  end

  def self.json_formatter
    ::Log::Formatter.new do |entry, io|
      # typeof doesn't execute anything
      json = {} of String => typeof(log_metadata_to_raw(entry.data[:check]))
      json["level"] = entry.severity.label
      json["time"] = entry.timestamp
      json["source"] = entry.source
      json["message"] = entry.message unless entry.message.empty?

      # Add context tags
      {entry.context, entry.data}.each &.each { |k, v| json[k.to_s] = log_metadata_to_raw(v) }

      if exception = entry.exception
        json["exception"] = exception.inspect_with_backtrace
      end
      json.to_json(io)
    end
  end

  def self.default_backend(io = STDOUT, formatter = default_formatter)
    backend = ::Log::IOBackend.new(io, formatter: formatter)
    backend
  end
end
