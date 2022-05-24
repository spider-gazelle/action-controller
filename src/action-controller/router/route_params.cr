module Route::Param
  # Handle this to return a 404
  class Error < ArgumentError
    def initialize(@message, @parameter = nil, @restriction = nil)
    end

    getter parameter : String?
    getter restriction : String?
  end

  class MissingError < Error
  end

  class ValueError < Error
  end

  # The method for building in support of different route params
  abstract struct Conversion
    abstract def convert(raw : String)
  end

  struct ConvertInt32 < Conversion
    def convert(raw : String)
      raw.to_i?
    end
  end

  struct ConvertString < Conversion
    def convert(raw : String)
      raw
    end
  end

  struct ConvertTime < Conversion
    def initialize(@format : String? = nil)
    end

    def convert(raw : String)
      if format = @format
        Time.parse raw, format
      else
        Time.parse_iso8601 raw
      end
    end
  end
end
