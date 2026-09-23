use ohkami::claw::{Json, Path};
use ohkami::prelude::*;
use std::sync::LazyLock;

static LARGE_JSON_DATA: LazyLock<String> = LazyLock::new(|| "x".repeat(100_000));
static LARGE_JSON_BODY: LazyLock<Vec<u8>> =
    LazyLock::new(|| format!("{{\"data\":\"{}\"}}", LARGE_JSON_DATA.as_str()).into_bytes());

#[derive(Serialize)]
struct Message {
    message: &'static str,
}

#[derive(Serialize)]
struct LargeMessage {
    data: &'static str,
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let port = std::env::args().nth(1).unwrap_or_else(|| "3000".to_owned());
    let address = format!("127.0.0.1:{port}");
    Ohkami::new((
        "/plain".GET(|| async { "OK" }),
        "/user/:id".GET(|Path(id): Path<String>| async move { id }),
        "/json".GET(|| async {
            Json(Message {
                message: "Hello, world!",
            })
        }),
        "/json-buffered".GET(|| async {
            Json(Message {
                message: "Hello, world!",
            })
        }),
        "/json-large".GET(|| async {
            Json(LargeMessage {
                data: LARGE_JSON_DATA.as_str(),
            })
        }),
        "/json-large-buffered".GET(|| async {
            Json(LargeMessage {
                data: LARGE_JSON_DATA.as_str(),
            })
        }),
        "/json-large-static".GET(|| async {
            Response::OK().with_payload("application/json", LARGE_JSON_BODY.as_slice())
        }),
    ))
    .howl(address)
    .await;
}
