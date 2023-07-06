require "big"
require "uuid"

# this namespace is used to provide transparent strong parameters
#
# all transparent converters need to match the desired Class name
# and be prefixed with `Convert`
#
# i.e. let's take a class like `Int32`
# ```
# struct AC::Route::Param::ConvertInt32 < AC::Route::Param::Conversion
#   def convert(raw : String)
#     raw.to_i
#   end
# end
# ```
#
# now if you would like to provide custom options for a converter you can.
#
# in this case we're allowing for a custom Int32 base, i.e. maybe you expect a hex string
# ```
# struct AC::Route::Param::ConvertInt32 < AC::Route::Param::Conversion
#   def initialize(@base : Int32 = 10)
#   end
#
#   def convert(raw : String)
#     raw.to_i(@base)
#   end
# end
#
# # then in your routes
# @[AC::Route::GET("/hex_route/:id", config: {id: {base: 16}})]
# def other_route_test(id : Int32) : Int32
#   id # response will be in base 10
# end
# ```
module ActionController::Route::Param
  # Handle this to return a 404
  class Error < ArgumentError
    def initialize(@message, @parameter = nil, @restriction = nil)
    end

    getter parameter : String?
    getter restriction : String?
  end

  # raised when a required param is missing from the request
  class MissingError < Error
  end

  # raised when a param is provided however the value is not parsable or usable
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

  # :nodoc:
  struct ConvertString < Conversion
    def convert(raw : String)
      raw
    end
  end

  # :nodoc:
  struct ConvertChar < Conversion
    def convert(raw : String)
      raw[0]?
    end
  end

  # :nodoc:
  struct ConvertBool < Conversion
    def initialize(@true_string : String = "true")
    end

    def convert(raw : String)
      raw.strip.downcase == @true_string
    end
  end

  # :nodoc:
  struct ConvertUUID < Conversion
    def initialize(@variant : UUID::Variant? = nil, @version : UUID::Version? = nil)
    end

    def convert(raw : String)
      UUID.parse?(raw, variant: @variant, version: @version)
    end
  end

  # :nodoc:
  struct ConvertEnum(T)
    def self.convert(raw : String)
      value = raw.to_i64? || raw
      case value
      in Int64
        T.from_value? value
      in String
        T.parse? value
      end
    end
  end

  # :nodoc:
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

  # :nodoc:
  struct ConvertBigInt < Conversion
    def initialize(@base : Int32 = 10)
    end

    def convert(raw : String)
      raw.to_big_i(@base)
    end
  end

  # Big converters

  {% begin %}
    {%
      bigs = {
        to_big_d: BigDecimal,
        to_big_f: BigFloat,
      }
    %}
    {% for convert, klass in bigs %}
      # :nodoc:
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
      # :nodoc:
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
      # :nodoc:
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
