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
        str << "level=" << label << " time="
        timestamp.to_rfc3339(str)
        str << " source=" << entry.source

        # Add context tags
        {context, data}.each &.each do |k, v|
          str << " " << k << "=" << v
        end

        str << " message=" << entry.message unless entry.message.empty?

        if exception = entry.exception
          str << "\n"
          exception.inspect_with_backtrace(str)
        end
      end
    end
  end

  def self.default_backend
    backend = ::Log::IOBackend.new
    backend.formatter = default_formatter
    backend
  end
end
