require "log"
require "log/backend"
require "log/io_backend"

require "http/server/context"

class HTTP::Server::Context
  # ameba:disable Style/ConstantNames
  Log = Log.for("action-controller")
end

module ActionController
  def self.default_formatter
    Log::Formatter.new do |entry, io|
      label = entry.severity.label.rjust(7)
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

  def self.init_logger
    backend = Log::IOBackend.new
    backend.formatter = default_formatter

    builder = Log::Builder.new
    builder.bind("action-controller", :info, backend)
  end

  init_logger
end
