require "log"

module ActionController
  # ameba:disable Style/ConstantNames
  Log = ::Log.for("action-controller")

  def self.default_formatter
    ::Log::Formatter.new do |entry, io|
      label = entry.severity.label.lstrip
      timestamp = entry.timestamp
      context = entry.context
      io << String.build do |str|
        str << "level=" << label << " time="
        timestamp.to_rfc3339(str)
        str << " source=" << entry.source

        # Add context tags
        context.as_h?.try &.each do |k, v|
          str << " " << k << "=" << v
        end
        str << " message=" << entry.message unless entry.message.empty?
      end
    end
  end

  def self.default_backend
    backend = ::Log::IOBackend.new
    backend.formatter = default_formatter
    backend
  end
end
