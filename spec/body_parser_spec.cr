require "./spec_helper"

describe ActionController::BodyParser do
  it "should add url encoded data into params" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    body = "home=Cosby&home=what&favorite+flavor=flies"
    request = HTTP::Request.new("POST", "/?home=test", headers, body)

    files, form_data = ActionController::BodyParser.extract_form_data(request, "application/x-www-form-urlencoded", request.query_params)
    form_data = form_data.not_nil!
    params = request.query_params

    params["home"].should eq("test")
    params.fetch_all("home").should eq(["test", "Cosby", "what"])
    form_data.fetch_all("home").should eq(["Cosby", "what"])

    params["favorite flavor"].should eq("flies")
    form_data["favorite flavor"].should eq("flies")

    files.should be(nil)
  end

  it "should add form data into params and file uploads into files" do
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=AaB03x"}
    body = <<-BODY
      --AaB03x
      Content-Disposition: form-data; name="submit-name"

      Larry
      --AaB03x
      Content-Disposition: form-data; name="files"; filename="file1.txt"
      Content-Type: text/plain

      ... contents of file1.txt ...
      --AaB03x--
      BODY

    body = body.gsub("\n", "\r\n")

    request = HTTP::Request.new("POST", "/?submit-name=test", headers, body)
    files, form_data = ActionController::BodyParser.extract_form_data(request, "multipart/form-data", request.query_params)
    form_data = form_data.not_nil!

    params = request.query_params
    params["submit-name"].should eq("test")
    params.fetch_all("submit-name").should eq(["test", "Larry"])
    form_data.fetch_all("submit-name").should eq(["Larry"])

    file = files.not_nil!["files"][0]
    file.filename.should eq("file1.txt")

    file.body.gets_to_end.should eq("... contents of file1.txt ...")
  end

  it "should add form data subpart file uploads into files" do
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=AaB03x"}
    body = <<-BODY
      --AaB03x
      Content-Disposition: form-data; name="submit-name"

      Larry
      --AaB03x
      Content-Disposition: form-data; name="files"
      Content-Type: multipart/mixed; boundary=BbC04y

      --BbC04y
      Content-Disposition: file; filename="file1.txt"
      Content-Type: text/plain

      ... contents of file1.txt ...
      --BbC04y
      Content-Disposition: file; filename="file2.gif"
      Content-Type: image/gif
      Content-Transfer-Encoding: binary

      ... contents of file2.gif ...
      --BbC04y--
      --AaB03x--
      BODY

    body = body.gsub("\n", "\r\n")

    request = HTTP::Request.new("POST", "/?submit-name=test", headers, body)
    files, form_data = ActionController::BodyParser.extract_form_data(request, "multipart/form-data", request.query_params)
    form_data = form_data.not_nil!

    params = request.query_params
    params["submit-name"].should eq("test")
    params.fetch_all("submit-name").should eq(["test", "Larry"])
    form_data.fetch_all("submit-name").should eq(["Larry"])

    file = files.not_nil!["files"][0]
    file.filename.should eq("file1.txt")
    file.body.to_s.should eq("... contents of file1.txt ...")

    file = files.not_nil!["files"][1]
    file.filename.should eq("file2.gif")
    file.body.to_s.should eq("... contents of file2.gif ...")
  end
end
