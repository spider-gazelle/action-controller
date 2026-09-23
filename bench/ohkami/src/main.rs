use ohkami::claw::{Json, Path};
use ohkami::prelude::*;

#[derive(Serialize)]
struct Message {
    message: &'static str,
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
    ))
    .howl(address)
    .await;
}
