require "openssl/hmac"
require "crypto/subtle"

module ActionController
end

class ActionController::MessageVerifier
  def initialize(@secret : String, @digest : OpenSSL::Algorithm = :sha1)
  end

  def prepare(value)
    generate(value)
  end

  def extract(value)
    verify_raw(value)
  end

  def valid_message?(data, digest)
    data.size > 0 && digest.size > 0 && Crypto::Subtle.constant_time_compare(digest, generate_digest(data))
  end

  def verified(signed_message : String)
    data, _match, digest = signed_message.rpartition("--")
    if digest && valid_message?(data, digest)
      String.new(decode(data))
    end
  rescue argument_error : ArgumentError
    return if argument_error.message =~ %r{invalid base64}
    raise argument_error
  end

  def verify(signed_message) : String
    verified(signed_message) || raise(InvalidSignature.new)
  end

  def verify_raw(signed_message : String) : Bytes
    data, _match, digest = signed_message.rpartition("--")
    if digest && valid_message?(data, digest)
      decode(data)
    else
      raise(InvalidSignature.new)
    end
  end

  def generate(value : String | Bytes)
    data = encode(value)
    "#{data}--#{generate_digest(data)}"
  end

  private def encode(data)
    ::Base64.strict_encode(data)
  end

  private def decode(data)
    ::Base64.decode(data)
  end

  private def generate_digest(data)
    encode(OpenSSL::HMAC.digest(@digest, @secret, data))
  end
end
