#!/usr/bin/env bash
# 交叉编译示例：C(Rust)/Windows/私有架构 最小验证。
# 在 sophon-tools-build 镜像内演示 8 架构交叉编译能力。
#
# 用法:
#   bash docker/examples/cross-test/run.sh [--image <name>]
set -u

IMAGE="${IMAGE:-sophon-tools-build:unified}"
[[ $# -ge 1 ]] && IMAGE="$1"

echo "== 使用镜像: ${IMAGE}"
docker run --rm -i "${IMAGE}" bash -s <<'EOF'
set -e
mkdir -p /tmp/x && cd /tmp/x

# 1) C aarch64 musl 静态
printf 'int main(void){return 0;}\n' > c.c
aarch64-linux-musl-gcc -static c.c -o c_arm64
echo "[1] C aarch64 musl:"; file c_arm64 | sed 's/^/    /'

# 2) Rust aarch64 musl 静态
cargo new --bin rtest >/dev/null 2>&1 && cd rtest
printf 'fn main(){println!("hello");}\n' > src/main.rs
cargo build --release --target aarch64-unknown-linux-musl >/dev/null 2>&1
echo "[2] Rust aarch64 musl:"; file target/aarch64-unknown-linux-musl/release/rtest | sed 's/^/    /'
cd ..

# 3) Windows x86_64 (mingw64)
printf 'int main(void){return 0;}\n' > w.c
x86_64-w64-mingw32-gcc -static w.c -o w64.exe
echo "[3] Windows x86_64:"; file w64.exe | sed 's/^/    /'

# 4) Windows i686 (mingw)
i686-w64-mingw32-gcc -static w.c -o w32.exe
echo "[4] Windows i686:"; file w32.exe | sed 's/^/    /'

# 5) sw_64 (dfss 私有工具链)
if [ -x /usr/sw/swgcc830_cross_tools/usr/bin/sw_64-sunway-linux-gnu-gcc ]; then
  /usr/sw/swgcc830_cross_tools/usr/bin/sw_64-sunway-linux-gnu-gcc -static c.c -o s.out 2>/dev/null
  echo "[5] sw_64:"; file s.out | sed 's/^/    /'
else
  echo "[5] sw_64: 工具链未内置(需 --with-dfss-toolchains 重建)"
fi

# 6) loongarch64 (dfss 私有工具链)
if [ -x /env/loongson-gnu-toolchain-8.3-x86_64-loongarch64-linux-gnu-rc1.1/bin/loongarch64-linux-gnu-gcc ]; then
  /env/loongson-gnu-toolchain-8.3-x86_64-loongarch64-linux-gnu-rc1.1/bin/loongarch64-linux-gnu-gcc -static c.c -o l.out 2>/dev/null
  echo "[6] loongarch64:"; file l.out | sed 's/^/    /'
else
  echo "[6] loongarch64: 工具链未内置(需 --with-dfss-toolchains 重建)"
fi

echo "== 交叉编译示例完成 =="
EOF
