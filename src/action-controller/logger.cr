require "logger"
require "http/server/context"

class HTTP::Server::Context
  @logger : ActionController::Logger::TaggedLogger? = nil

  def logger : ActionController::Logger::TaggedLogger
    @logger ||= ActionController::Logger::TaggedLogger.new(
      ActionController::Base.settings.logger
    )
  end
end

class ActionController::Logger < Logger
  TAGS = [] of Nil

  macro add_tag(name)
    {% TAGS << name.id %}
  end

  class TaggedLogger < Logger
    def initialize(@logger : ::Logger)
      super(STDOUT)
      @level = @logger.level
    end

    def close
    end

    macro finished
      {% for tag in TAGS %}
        property {{tag}} : String?
      {% end %}

      def tags
        {% if !TAGS.empty? %}
          {
            {% for tag in TAGS %}
              {{tag}}: @{{tag}},
            {% end %}
          }
        {% else %}
          NamedTuple.new
        {% end %}
      end
    end

    {% for name in Logger::Severity.constants %}
      def {{name.id.downcase}}(message, progname = nil)
        severity = Severity::{{name.id}}
        return if severity < @level

        @logger.log(severity, message, build_tags(progname))
      end

      def {{name.id.downcase}}(progname = nil)
        severity = Severity::{{name.id}}
        return if severity < @level

        @logger.log(severity, yield, build_tags(progname))
      end
    {% end %}

    def build_tags(progname)
      String.build do |str|
        str << " progname=" << progname if progname
        tags.each do |tag, value|
          str << " " << tag << "=" << value if value
        end
      end
    end

    def log(severity, message, progname = nil)
      return if severity < @level
      @logger.log(severity, message, build_tags(progname))
    end

    def log(severity, progname = nil)
      return if severity < @level
      @logger.log(severity, yield, build_tags(progname))
    end

    def tag(message : String = "", progname = nil, severity : Logger::Severity = Logger::Severity::INFO, **tags)
      return if severity < @level
      standard_tags = build_tags(progname)
      custom_tags = String.build do |str|
        tags.each do |tag, value|
          str << " " << tag << "=" << value if value
        end
      end
      @logger.log(severity, message, "#{standard_tags}#{custom_tags}")
    end

    {% for level in Logger::Severity.constants %}
      def tag_{{level.downcase.id}}(message : String = "", progname = nil, **tags)
        tag(message, progname, Logger::Severity::{{ level }}, **tags)
      end
    {% end %}
  end

  def initialize(io = STDOUT)
    super(io)
    self.formatter = default_format
  end

  def default_format
    Logger::Formatter.new do |severity, datetime, progname, message, io|
      label = severity.unknown? ? "ANY" : severity.to_s
      io << String.build do |str|
        str << "level=" << label << " time="
        datetime.to_rfc3339(str)
        str << progname if progname
        str << " message=" << message if message && !message.empty?
      end
    end
  end
end
