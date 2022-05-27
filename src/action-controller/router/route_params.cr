require "big"

module ActionController::Route::Param
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
    # convert should typically return nil if the conversion failed
    # this allows support for Union types, however may not be practical
    # or desirable for most.
    #
    # Nilable Unions against a single type that raises an error is supported
    abstract def convert(raw : String)
  end

  struct ConvertString < Conversion
    def convert(raw : String)
      raw
    end
  end

  struct ConvertChar < Conversion
    def convert(raw : String)
      raw[0]?
    end
  end

  struct ConvertBool < Conversion
    def initialize(@true_string : String = "true")
    end

    def convert(raw : String)
      raw.strip.downcase == @true_string
    end
  end

  struct ConvertTime < Conversion
    def initialize(@format : String? = nil)
    end

    def convert(raw : String)
      if format = @format
        Time.parse_utc raw, format
      else
        Time.parse_iso8601 raw
      end
    end
  end

  struct ConvertBigInt < Conversion
    def initialize(@base : Int32 = 10)
    end

    def convert(raw : String)
      raw.to_big_i(@base)
    end
  end

  {% begin %}
    # Big converters
    {%
      bigs = {
        to_big_d: BigDecimal,
        to_big_f: BigFloat,
      }
    %}
    {% for convert, klass in bigs %}
      struct Convert{{klass}} < Conversion
        def convert(raw : String)
          raw.{{convert}}?
        end
      end
    {% end %}

    # Float converters
    {%
      floats = {
        to_f32: Float32,
        to_f64: Float64,
      }
    %}
    {% for convert, klass in floats %}
      struct Convert{{klass}} < Conversion
        def initialize(@whitespace : Bool = true, @strict : Bool = true)
        end

        def convert(raw : String)
          raw.{{convert}}?(
            whitespace: @whitespace,
            strict: @strict,
          )
        end
      end
    {% end %}

    # Integer converters
    {%
      ints = {
        to_i8:   Int8,
        to_u8:   UInt8,
        to_i16:  Int16,
        to_u16:  UInt16,
        to_i32:  Int32,
        to_u32:  UInt32,
        to_i64:  Int64,
        to_u64:  UInt64,
        to_i128: Int128,
        to_u128: UInt128,
      }
    %}
    {% for convert, klass in ints %}
      struct Convert{{klass}} < Conversion
        def initialize(@base : Int32 = 10, @whitespace : Bool = true, @underscore : Bool = false, @prefix : Bool = false, @strict : Bool = true, @leading_zero_is_octal : Bool = false)
        end

        def convert(raw : String)
          raw.{{convert}}?(
            base: @base,
            whitespace: @whitespace,
            underscore: @underscore,
            prefix: @prefix,
            strict: @strict,
            leading_zero_is_octal: @leading_zero_is_octal
          )
        end
      end
    {% end %}
  {% end %}
end
