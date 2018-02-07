
module ActionController::BodyParser
  CONTENT_TYPES = {
    "application/x-www-form-urlencoded": :url_encoded_form,
    "application/x-url-encoded":         :url_encoded_form,
    "multipart/form-data":               :multipart_form,
  }

  struct FileUpload
    getter body : IO

    getter name : String
    getter headers : HTTP::Headers

    getter filename : String?
    getter creation_time : Time?
    getter modification_time : Time?
    getter read_time : Time?
    getter size : UInt64?

    def initialize(part : HTTP::FormData::Part)
      @name = part.name
      @headers = part.headers
      @filename = part.filename
      @creation_time = part.creation_time
      @modification_time = part.modification_time
      @read_time = part.read_time
      @size = part.size

      @body = IO::Memory.new(part.body.gets_to_end)
    end
  end

  def self.extract_form_data(request, content_type, params : HTTP::Params)
    body = request.body
    return unless body

    ctype = CONTENT_TYPES[content_type]?
    return unless ctype

    case ctype
    when :url_encoded_form
      # Add the form data to the request params
      form_params = HTTP::Params.parse(body.gets_to_end)
      form_params.each do |key, val|
        values = params.fetch_all(key) || [] of String
        values.concat(form_params.fetch_all(key))
        params.set_all(key, values)
      end

    when :multipart_form
      files = {} of String => Array(FileUpload)

      # Ref: https://www.w3.org/TR/html401/interact/forms.html#h-17.13.4.2
      HTTP::FormData.parse(request) do |part|
        data_type = part.headers["Content-Type"]?
        filename = part.filename
        if data_type || (filename && !filename.empty?)
          # Check if this is a list of files
          if data_type && data_type.starts_with? "multipart/mixed"
            boundary = HTTP::Multipart.parse_boundary(data_type)
            next unless boundary

            parser = HTTP::FormData::Parser.new(part.body, boundary)
            parts = files[part.name] = [] of FileUpload

            while parser.has_next?
              parser.next { |part| parts << FileUpload.new(part) }
            end
          else
            # This is a single file
            files[part.name] = [FileUpload.new(part)]
          end
        else
          # This is some form data, add it to params
          params.add(part.name, part.body.gets_to_end)
        end
      end

      return files unless files.empty?
    end
  end
end
