require "./spec_helper"

describe "template responses" do
  client = AC::SpecHelper.client

  it "test base class" do
    result = client.get("/template_one/")
    result.body.should eq("<!DOCTYPE html>\n<html>\n<head>\n\t<title>Fortunes</title>\n</head>\n<body>\n\t<p>inner 127.0.0.1</p>\n\n</body>\n</html>\n")
  end

  it "test base class with render helper" do
    result = client.get("/template_one/?inline=true")
    result.body.should eq("<!DOCTYPE html>\n<html>\n<head>\n\t<title>Fortunes</title>\n</head>\n<body>\n\t<p>inner 127.0.0.1</p>\n\n</body>\n</html>\n")
  end

  it "test partials" do
    result = client.get("/template_one/111")
    result.body.should eq("<p>inner 111</p>\n")
  end

  it "test partials with render helper" do
    result = client.get("/template_one/111?inline=true")
    result.body.should eq("<p>inner 111</p>\n")
  end

  it "test inheritance and template includes" do
    result = client.get("/template_two")
    result.body.should eq("<!DOCTYPE html>\n<html>\n<head>\n\t<title>Alt</title>\n</head>\n<body>\n\t<p>inner 50</p>\n\n\t<p>inner 50</p>\n\n</body>\n</html>\n")
  end
end
