use std::env;
use std::fs;
use std::path::Path;

fn main() {
    // 编译时版本优先取 env（由 release.sh 注入，见 MYS-58 S-2），
    // 避免统一构建时改写仓库跟踪的 .git_version 文件而弄脏工作区。
    println!("cargo:rerun-if-env-changed=BM_SET_IP_GIT_VERSION");
    if let Ok(v) = env::var("BM_SET_IP_GIT_VERSION") {
        if !v.trim().is_empty() {
            println!("cargo:rustc-env=GIT_TAG_COMMIT={}", v.trim());
            return;
        }
    }

    // 回退：读取 .git_version 文件内容（直接 bash build.sh 时使用已提交的默认值）
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let git_version_path = Path::new(&manifest_dir).join(".git_version");
    let git_version = fs::read_to_string(&git_version_path)
        .unwrap_or_else(|_| panic!("Failed to read {:?}", git_version_path))
        .trim()
        .to_string();

    println!("cargo:rustc-env=GIT_TAG_COMMIT={}", git_version);
    println!("cargo:rerun-if-changed={}", git_version_path.display());
}
