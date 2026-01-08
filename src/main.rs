use axum::{
    Router,
    extract::Query,
    response::{IntoResponse, Json},
    routing::get,
};
use serde::Deserialize;
use serde_json::Value;
use std::net::SocketAddr;

#[derive(Deserialize)]
struct MergeParams {
    template: String, // sing-box 模板 URL
    nodes: String,    // Sub-Store 节点 JSON URL
}

#[tokio::main]
async fn main() {
    let app = Router::new().route("/merge", get(handle_merge));

    let addr = SocketAddr::from(([0, 0, 0, 0], 3002));
    println!("服务运行在 http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn handle_merge(Query(params): Query<MergeParams>) -> impl IntoResponse {
    match perform_merge(&params.template, &params.nodes).await {
        Ok(merged_config) => Json(merged_config).into_response(),
        Err(e) => (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            format!("Error: {}", e),
        )
            .into_response(),
    }
}

async fn perform_merge(template_url: &str, nodes_url: &str) -> anyhow::Result<Value> {
    let client = reqwest::Client::new();

    // 1. 并发获取模板和节点数据
    let (template_res, nodes_res) = tokio::join!(
        client.get(template_url).send(),
        client.get(nodes_url).send()
    );

    let mut template_json: Value = template_res?.json().await?;
    let nodes_data: Value = nodes_res?.json().await?;

    // 2. 解析 Sub-Store 输出的节点
    // Sub-Store 如果导出格式是 sing-box，通常是一个包含 outbounds 的对象，
    // 或者直接就是一个包含节点列表的数组。
    let new_nodes = if let Some(outbounds) = nodes_data.get("outbounds") {
        outbounds.as_array().cloned()
    } else {
        nodes_data.as_array().cloned()
    };

    let new_nodes = new_nodes.ok_or_else(|| anyhow::anyhow!("无法从 nodes_url 解析到节点列表"))?;

    let node_tags: Vec<Value> = new_nodes
        .iter()
        .filter_map(|n| n.get("tag"))
        .cloned()
        .collect();

    // 3. 将节点合并到模板中
    if let Some(template_outbounds) = template_json
        .get_mut("outbounds")
        .and_then(|v| v.as_array_mut())
    {
        template_outbounds
            .iter_mut()
            .filter(|o| {
                // 筛选条件：tag
                let tag = o["tag"].as_str().unwrap_or("");
                tag == "🚀 节点选择" || tag == "🎈 自动选择"
            })
            .for_each(|outbound| {
                // 这里的 outbound 是满足条件的 &mut Value
                if let Some(sub_outbounds) =
                    outbound.get_mut("outbounds").and_then(|o| o.as_array_mut())
                {
                    sub_outbounds.extend(node_tags.clone());
                }
            });
        template_outbounds.extend(new_nodes);
    } else {
        // 如果模板里没有 outbounds，则创建一个
        template_json["outbounds"] = Value::Array(new_nodes);
    }

    Ok(template_json)
}
