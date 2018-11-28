require "./spec_helper"

describe "template responses" do
  with_server do
    it "test base class" do
      result = curl("GET", "/template_one/")
      result.body.should eq("<!DOCTYPE html>\n<html>\n<head>\n\t<title>Fortunes</title>\n</head>\n<body>\n\t<p>inner 45</p>\n\n</body>\n</html>\n")
    end

    it "test partials" do
      result = curl("GET", "/template_one/111")
      result.body.should eq("<p>inner 111</p>\n")
    end

    it "test inheritance and template includes" do
      result = curl("GET", "/template_two")
      result.body.should eq("<!DOCTYPE html>\n<html>\n<head>\n\t<title>Alt</title>\n</head>\n<body>\n\t<p>inner 50</p>\n\n\t<p>inner 50</p>\n\n</body>\n</html>\n")
    end
  end
end
