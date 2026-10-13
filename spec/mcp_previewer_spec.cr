require "./spec_helper"
require "../src/action-controller/mcp"

PREVIEWER_PORT = 6_124
PREVIEWER_URI  = "http://127.0.0.1:#{PREVIEWER_PORT}"

# the JSON settings embedded in a tool page
private def previewer_config(html : String) : JSON::Any
  json = html.match!(%r{<script type="application/json" id="previewer-config">(.*?)</script>}m)[1]
  JSON.parse(json)
end

describe ActionController::MCPServer::CardPreviewer do
  server = ActionController::Server.new(PREVIEWER_PORT, "127.0.0.1")
  # not the default path, the previewer finds it
  ActionController::MCPServer.mount(server, "/assistant/mcp")

  before_all do
    ActionController::MCPServer.description = nil
    ActionController::MCPServer.ui_base = File.join(__DIR__, "cards")
    bound = Channel(Nil).new
    spawn do
      server.run do
        # mounted like an application would, before the routes are compiled
        server.mount_mcp_card_previewer("/mcp/card/preview/")
        bound.send nil
      end
    end
    bound.receive
  end

  after_all do
    server.close
    ActionController::MCPServer.ui_base = nil
  end

  it "lists the cards with the tools that render them" do
    response = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview")
    response.status_code.should eq 200
    response.content_type.should eq "text/html"
    response.headers["Cache-Control"].should eq "no-store"

    html = response.body
    bookings = html[html.index!(%(data-card="ui://bookings/card.html"))..]
    bookings = bookings[...bookings.index!("</section>")]
    bookings.should contain %(href="/mcp/card/preview/tools/mcp_ui_show")
    bookings.should contain %(href="/mcp/card/preview/tools/mcp_ui_history")
    bookings.should contain "not a root tool"
    bookings.should_not contain "mcp_ui_rooms"
    html.should contain %(data-card="ui://rooms/card.html")
    html.should contain %(href="/mcp/card/preview/tools/mcp_ui_rooms")

    # card-only tools are listed, but not previewed
    html.should contain "Card-only tools"
    html.should contain "mcp_ui_check_in"
    html.should_not contain "/tools/mcp_ui_check_in"
    # tools without a card aren't listed
    html.should_not contain "mcp_widgets_colours"
    html.should_not contain "Cards aren't served"
  end

  it "warns when cards aren't served" do
    ActionController::MCPServer.ui_base = nil
    html = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview").body
    html.should contain "Cards aren't served"
    html.should contain "Card file not found"
  ensure
    ActionController::MCPServer.ui_base = File.join(__DIR__, "cards")
  end

  it "renders a tool's page" do
    response = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview/tools/mcp_ui_show")
    response.status_code.should eq 200
    html = response.body
    html.should contain %(<form id="args-form")
    html.should contain "window.cardPreviewer"

    config = previewer_config(html)
    config["mcp"].should eq "/assistant/mcp"
    config["index"].should eq "/mcp/card/preview"
    tool = config["tool"]
    tool["name"].should eq "mcp_ui_show"
    tool["verb"].should eq "GET"
    tool["ui"].should eq "ui://bookings/card.html"
    tool["found"].should be_true
    tool["root"].should be_true
    tool["inputSchema"]["required"].should eq JSON.parse(%(["id"]))
  end

  it "names the toolbox to open for tools that aren't root tools" do
    tool = previewer_config(HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview/tools/mcp_ui_history").body)["tool"]
    tool["root"].should be_false
    tool["toolbox"].should eq "mcp_ui"
  end

  it "returns 404 for unknown tools and tools without a card" do
    unknown = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview/tools/missing")
    unknown.status_code.should eq 404
    unknown.body.should contain "unknown tool missing"

    plain = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview/tools/mcp_ui_check_in")
    plain.status_code.should eq 404
    plain.body.should contain "mcp_ui_check_in doesn&#39;t render a card"
  end

  it "escapes values in the page" do
    response = HTTP::Client.get("#{PREVIEWER_URI}/mcp/card/preview/tools/%3Cscript%3E")
    response.status_code.should eq 404
    response.body.should contain "unknown tool &lt;script&gt;"
  end

  it "requires the MCP server to be mounted first, unless its path is provided" do
    other = ActionController::Server.new(PREVIEWER_PORT + 1, "127.0.0.1")
    expect_raises(ArgumentError, /mount the MCP server before the card previewer/) do
      other.mount_mcp_card_previewer
    end
    other.mount_mcp_card_previewer(mcp: "/prefix/mcp").mcp.should eq "/prefix/mcp"
  end

  it "responds to HEAD without a body" do
    response = HTTP::Client.head("#{PREVIEWER_URI}/mcp/card/preview")
    response.status_code.should eq 200
    response.body.should be_empty
  end
end
