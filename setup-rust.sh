#!/usr/bin/env bash
#
# setup-rust.sh —— 一键恢复 / 检查 Rust 开发环境（macOS / Linux）
#
# 幂等脚本：已装好的部分会跳过，只补缺失的，可安全重复运行。
#
#  1. 确定安装位置（默认沿用 Unix 惯例 ~/.rustup + ~/.cargo）
#  2. 配置镜像（auto 会实测延迟选最快）
#  3. 安装或修复 rustup 与 stable 工具链（含 clippy / rustfmt）
#  4. 写 cargo 的 crates.io 镜像配置
#  5. 端到端验证：新建临时项目、拉真实依赖、编译、跑 clippy
#
# 用法：
#   ./setup-rust.sh
#   ./setup-rust.sh --mirror rsproxy
#   ./setup-rust.sh --root "$HOME/.local/rust" --mirror none
#   ./setup-rust.sh --skip-verify
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# 参数
# ─────────────────────────────────────────────────────────────
MIRROR="auto"
CUSTOM_ROOT=""
SKIP_VERIFY=0

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

选项：
  -r, --root DIR      安装根目录（默认沿用 ~/.rustup + ~/.cargo，即不改动）
  -m, --mirror NAME   auto(默认) | tuna | rsproxy | ustc | none
      --skip-verify   跳过端到端编译验证
  -h, --help          显示本帮助
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--root)     CUSTOM_ROOT="${2:-}"; shift 2 ;;
        -m|--mirror)   MIRROR="${2:-}";      shift 2 ;;
        --skip-verify) SKIP_VERIFY=1;        shift   ;;
        -h|--help)     usage ;;
        *) echo "未知参数：$1（用 -h 查看帮助）" >&2; exit 2 ;;
    esac
done

case "$MIRROR" in
    auto|tuna|rsproxy|ustc|none) ;;
    *) echo "无效的 --mirror 值：$MIRROR" >&2; exit 2 ;;
esac

# ─────────────────────────────────────────────────────────────
# 输出 helper
# ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_STEP=$'\033[36m'; C_OK=$'\033[32m'
    C_INFO=$'\033[90m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'
else
    C_RESET=; C_STEP=; C_OK=; C_INFO=; C_WARN=; C_BAD=
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s%s%s\n' "$C_STEP" "------------------------------------------------------------" "$C_RESET"
         printf '%s [%d] %s%s\n' "$C_STEP" "$STEP_NO" "$1" "$C_RESET"
         printf '%s%s%s\n' "$C_STEP" "------------------------------------------------------------" "$C_RESET"; }
ok()   { printf '%s  [ok] %s%s\n' "$C_OK"   "$1" "$C_RESET"; }
info() { printf '%s  [..] %s%s\n' "$C_INFO" "$1" "$C_RESET"; }
warn() { printf '%s  [!!] %s%s\n' "$C_WARN" "$1" "$C_RESET"; }
bad()  { printf '%s  [xx] %s%s\n' "$C_BAD"  "$1" "$C_RESET"; }

die() { bad "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────
# 1. 安装位置
# ─────────────────────────────────────────────────────────────
step '确定安装位置'

if [ -n "$CUSTOM_ROOT" ]; then
    RUSTUP_HOME_DIR="$CUSTOM_ROOT/rustup"
    CARGO_HOME_DIR="$CUSTOM_ROOT/cargo"
    info "使用自定义根目录：$CUSTOM_ROOT"
else
    # Unix 惯例：很多工具（IDE 插件、CI 脚本）都假定这两个路径，不要轻易改
    RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
    CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
    info '使用 Unix 惯例路径（未指定 --root）'
fi
info "RUSTUP_HOME = $RUSTUP_HOME_DIR"
info "CARGO_HOME  = $CARGO_HOME_DIR"

# ─────────────────────────────────────────────────────────────
# 2. 检查依赖命令
# ─────────────────────────────────────────────────────────────
step '检查依赖命令'

for c in curl; do
    command -v "$c" >/dev/null 2>&1 || die "缺少必需命令：$c"
    ok "$c 可用"
done

# ─────────────────────────────────────────────────────────────
# 3. 镜像选型
# ─────────────────────────────────────────────────────────────
step '选择镜像'

mirror_url() {
    case "$1" in
        tuna)    echo 'https://mirrors.tuna.tsinghua.edu.cn/rustup' ;;
        rsproxy) echo 'https://rsproxy.cn' ;;
        ustc)    echo 'https://mirrors.ustc.edu.cn/rust-static' ;;
    esac
}

DIST_SERVER=""
CRATES_INDEX=""

if [ "$MIRROR" = "none" ]; then
    info '使用官方源（static.rust-lang.org / crates.io）'
else
    CHOSEN="$MIRROR"
    if [ "$MIRROR" = "auto" ]; then
        info '实测各镜像延迟…'
        BEST=""; BEST_MS=999999
        for name in tuna rsproxy ustc; do
            url="$(mirror_url "$name")"
            t=$(curl -s -o /dev/null -w '%{time_total}' --max-time 15 \
                    "$url/dist/channel-rust-stable.toml" 2>/dev/null || echo 99)
            ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000}')
            if [ "$ms" -lt 15000 ]; then
                info "$(printf '%-8s %6s ms' "$name" "$ms")"
                if [ "$ms" -lt "$BEST_MS" ]; then BEST_MS="$ms"; BEST="$name"; fi
            else
                warn "$(printf '%-8s 不可达' "$name")"
            fi
        done
        if [ -n "$BEST" ]; then
            CHOSEN="$BEST"; info "选中 -> $BEST (${BEST_MS} ms)"
        else
            CHOSEN="none"; warn '国内镜像全部不可达 -> 改用官方源'
        fi
    fi

    if [ "$CHOSEN" != "none" ]; then
        DIST_SERVER="$(mirror_url "$CHOSEN")"
        # crates.io：只有 rsproxy 的下载也走自家 CDN，其它镜像的 dl 仍指向国外
        CRATES_INDEX='sparse+https://rsproxy.cn/index/'
        if [ "$CHOSEN" != "rsproxy" ]; then
            info "rustup 用 $CHOSEN；crates.io 用 rsproxy（下载走国内 CDN）"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────
# 4. 环境变量
# ─────────────────────────────────────────────────────────────
step '设置环境变量'

export RUSTUP_HOME="$RUSTUP_HOME_DIR"
export CARGO_HOME="$CARGO_HOME_DIR"

if [ "$DIST_SERVER" != "" ]; then
    export RUSTUP_DIST_SERVER="$DIST_SERVER"
    export RUSTUP_UPDATE_ROOT="$DIST_SERVER/rustup"
    ok "RUSTUP_DIST_SERVER -> $DIST_SERVER"
else
    unset RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT 2>/dev/null || true
    ok '未设置镜像变量（走官方源）'
fi

if [ -n "$CUSTOM_ROOT" ]; then
    warn '你指定了自定义 --root。为了让新 shell 也生效，需要把下面几行写进 shell 配置：'
    printf '%s\n' "$C_INFO"
    printf '    export RUSTUP_HOME="%s"\n' "$RUSTUP_HOME_DIR"
    printf '    export CARGO_HOME="%s"\n'  "$CARGO_HOME_DIR"
    if [ "$DIST_SERVER" != "" ]; then
        printf '    export RUSTUP_DIST_SERVER="%s"\n' "$DIST_SERVER"
        printf '    export RUSTUP_UPDATE_ROOT="%s/rustup"\n' "$DIST_SERVER"
    fi
    printf '    export PATH="$CARGO_HOME/bin:$PATH"\n'
    printf '%s\n' "$C_RESET"
    info '加到 ~/.bashrc 或 ~/.zshrc 即可'
fi

# PATH（仅当前会话；持久化交由上面的提示或 rustup 默认行为）
case ":$PATH:" in
    *":$CARGO_HOME_DIR/bin:"*) ok "PATH 已含 $CARGO_HOME_DIR/bin" ;;
    *) export PATH="$CARGO_HOME_DIR/bin:$PATH"; ok "PATH += $CARGO_HOME_DIR/bin（当前会话）" ;;
esac

# ─────────────────────────────────────────────────────────────
# 5. 安装 rustup
# ─────────────────────────────────────────────────────────────
step '安装 / 检查 rustup'

if command -v rustup >/dev/null 2>&1; then
    ok "rustup 已存在：$(command -v rustup)"
else
    os="$(uname -s)"
    case "$os" in
        Linux)  plat='unknown-linux-gnu' ;;
        Darwin) plat='apple-darwin' ;;
        *) die "不支持的系统：$os（Windows 请用 setup-rust.ps1）" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  cpu='x86_64' ;;
        aarch64|arm64) cpu='aarch64' ;;
        armv7l)        cpu='armv7' ;;
        *)             cpu="$(uname -m)" ;;
    esac
    target="${cpu}-${plat}"
    info "目标平台：$target"

    if [ "$DIST_SERVER" != "" ]; then
        init_url="$DIST_SERVER/rustup/dist/$target/rustup-init"
    else
        init_url="https://static.rust-lang.org/rustup/dist/$target/rustup-init"
    fi
    # 官方推荐入口（仅官方源时可用）
    if [ "$DIST_SERVER" = "" ]; then
        init_url='https://sh.rustup.rs'
    fi

    tmp_init="$(mktemp)"
    trap 'rm -f "$tmp_init"' EXIT

    info "下载 $init_url"
    if ! curl -fsSL --compressed --max-time 180 -o "$tmp_init" "$init_url"; then
        die "下载失败。若在中国大陆，请加 --mirror 指定镜像。"
    fi
    ok "已下载 $(du -h "$tmp_init" | cut -f1)"

    info '静默安装（-y，不改 PATH）'
    sh "$tmp_init" -y --no-modify-path --default-toolchain none
    rm -f "$tmp_init"; trap - EXIT

    command -v rustup >/dev/null 2>&1 || die 'rustup 安装后仍不可用'
    ok 'rustup 安装完成'
fi

# ─────────────────────────────────────────────────────────────
# 6. stable 工具链
# ─────────────────────────────────────────────────────────────
step '安装 stable 工具链（含 clippy / rustfmt）'
info '（首次安装约 130 MB）'

rustup toolchain install stable --profile default -c rustfmt -c clippy || \
    warn "rustup toolchain install 退出码 $?"
rustup default stable

probe="$(rustc --version 2>&1 || true)"
if ! printf '%s' "$probe" | grep -q '^rustc [0-9]'; then
    warn "工具链异常：$probe"
    warn '尝试强制重装…'
    rustup toolchain install stable --force --profile default -c rustfmt -c clippy || true
    probe="$(rustc --version 2>&1 || true)"
fi
if printf '%s' "$probe" | grep -q '^rustc [0-9]'; then ok "$probe"; else bad "rustc 仍不可用：$probe"; fi

# ─────────────────────────────────────────────────────────────
# 7. cargo 的 crates.io 镜像
# ─────────────────────────────────────────────────────────────
step '配置 crates.io 镜像'

cargo_config="$CARGO_HOME_DIR/config.toml"
mkdir -p "$CARGO_HOME_DIR"

if [ -n "$CRATES_INDEX" ]; then
    content="# 由 setup-rust.sh 生成 -- 国内镜像加速
# 索引与下载均走 rsproxy CDN（其它国内镜像的 dl 仍指向国外）

[source.crates-io]
replace-with = \"rsproxy-sparse\"

[source.rsproxy-sparse]
registry = \"$CRATES_INDEX\"

[registries.rsproxy]
index = \"$CRATES_INDEX\"

[net]
git-fetch-with-cli = true
retry = 3"

    if [ -f "$cargo_config" ] && [ "$(cat "$cargo_config")" = "$content" ]; then
        ok 'config.toml 内容已是最新'
    else
        printf '%s\n' "$content" > "$cargo_config"
        ok "已写入 $cargo_config"
    fi
else
    if [ -f "$cargo_config" ]; then
        rm -f "$cargo_config"; ok '已移除镜像配置（走官方源）'
    else
        ok '无需镜像配置'
    fi
fi

# ─────────────────────────────────────────────────────────────
# 8. 端到端验证
# ─────────────────────────────────────────────────────────────
if [ "$SKIP_VERIFY" -eq 0 ]; then
    step '端到端验证'

    tmp_proj="$(mktemp -d)"
    trap 'rm -rf "$tmp_proj"' EXIT

    info "创建临时项目：$tmp_proj"
    if ! cargo new "$tmp_proj" --bin -q; then
        bad 'cargo new 失败'
    else
        (
            cd "$tmp_proj"
            start=$(date +%s)
            info '拉取依赖 serde…'
            if cargo add serde --features derive -q; then
                ok "cargo add 成功（$(( $(date +%s) - start ))s）"
            else
                warn "cargo add 退出码 $?"
            fi

            start=$(date +%s)
            info '编译…'
            if cargo build -q; then
                ok "cargo build 成功（$(( $(date +%s) - start ))s）"
            else
                bad 'cargo build 失败'
            fi

            if cargo clippy --all-targets >/dev/null 2>&1; then
                ok 'cargo clippy 通过'
            else
                warn "cargo clippy 退出码 $?"
            fi

            if cargo fmt --check >/dev/null 2>&1; then ok 'cargo fmt 可执行'; fi
            if cargo test -q   >/dev/null 2>&1; then ok 'cargo test 可执行'; fi
        )
    fi
    rm -rf "$tmp_proj"; trap - EXIT
fi

# ─────────────────────────────────────────────────────────────
# 汇总
# ─────────────────────────────────────────────────────────────
step '完成'

printf '\n'
info "RUSTUP_HOME = $RUSTUP_HOME_DIR"
info "CARGO_HOME  = $CARGO_HOME_DIR"
info "PATH        = $CARGO_HOME_DIR/bin"
printf '\n'
ok "$(rustc   --version 2>&1 || echo 'rustc 不可用')"
ok "$(cargo   --version 2>&1 || echo 'cargo 不可用')"
ok "$(rustfmt --version 2>&1 || echo 'rustfmt 不可用')"
cl="$(cargo clippy --version 2>&1 || true)"
case "$cl" in *clippy*) ok "$cl" ;; *) warn 'clippy 不可用' ;; esac
printf '\n'
if [ "$DIST_SERVER"  != "" ]; then info "镜像 rustup    : $DIST_SERVER";  fi
if [ "$CRATES_INDEX" != "" ]; then info "镜像 crates.io : $CRATES_INDEX"; fi
printf '\n'
warn '若当前 shell 未生效，请新开一个终端（环境变量需新进程才能读到）'
printf '\n'
