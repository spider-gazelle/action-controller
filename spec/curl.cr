# Just curl localhost where mock server is listening

def curl(method : String, path : String, headers = {} of String => String) : HTTP::Client::Response?
  client = HTTP::Client.new "localhost", 3000

  head = HTTP::Headers.new
  headers.each do |key, value|
    head[key] = value
  end

  response = nil
  case method
  when "GET"
    response = client.get path, head
  when "POST"
    response = client.post path, head
  when "PUT"
    response = client.put path, head
  when "PATCH"
    response = client.patch path, head
  when "DELETE"
    response = client.delete path, head
  end

  client.close

  response
end
