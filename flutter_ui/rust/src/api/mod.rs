//! FFI 接口层。每个模块对应 cdata-core 的一块能力，只做翻译不含业务规则。
pub mod connections;
pub mod db;
pub mod editor;
pub mod layouts;
pub mod options;
pub mod preferences;
pub mod schema;
pub mod value;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
