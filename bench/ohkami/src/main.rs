use ohkami::claw::Path;
use ohkami::prelude::*;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let port = std::env::args().nth(1).unwrap_or_else(|| "3000".to_owned());
    let address = format!("127.0.0.1:{port}");
    Ohkami::new((
        "/plain".GET(|| async { "OK" }),
        "/user/:id".GET(|Path(id): Path<String>| async move { id }),
    ))
    .howl(address)
    .await;
}
