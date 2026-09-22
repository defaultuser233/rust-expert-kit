# Rust 专家套件（Agent 中立版）

把 Rust 专业知识从「某个 Agent 的私有配置」变成「**一份可移植的内核**」。

---

## 目录内容

```
rust-expert-kit/
├── AGENTS.md          ← 指令层：复制到你的 Rust 项目根目录即可生效
├── setup-rust.ps1     ← 验证层：Windows 环境一键恢复
├── setup-rust.sh      ← 验证层：macOS / Linux 环境一键恢复
└── README.md
```

---

## 快速使用

### 方式 1：直接复制（推荐）

把 `AGENTS.md` 复制到你的 Rust 项目根目录：

```
your-rust-project/
├── AGENTS.md        ← 放这里
├── Cargo.toml
└── src/
```

**大多数 Agent 会自动读取它，零配置。**

### 方式 2：子模块化（大项目）

```
your-workspace/
├── AGENTS.md                  ← 全局规范
├── crates/
│   ├── parser/
│   │   └── AGENTS.md          ← parser 专属规则（就近优先，覆盖全局）
│   └── cli/
│       └── AGENTS.md
```

Agent 读**离被编辑文件最近**的那个 `AGENTS.md`。
（OpenAI 主仓库目前有 88 个 `AGENTS.md`，就是这么用的）

---

## 各 Agent 的兼容情况

`AGENTS.md` 是当前**事实上的跨 Agent 标准**，由 Linux 基金会下的
[Agentic AI Foundation](https://aaif.io/) 托管，已被 **60,000+ 开源项目**采用。

### 原生支持（直接读，零配置）

| Agent | 说明 |
|---|---|
| **GitHub Copilot** | VS Code / Coding Agent 均支持 |
| **Kimi Code** | 官方配置文档明确读取 `AGENTS.md`（含热重载）|
| **OpenAI Codex** | 标准发起方之一 |
| **Cursor** | 标准发起方之一 |
| **Zed** | 支持 |
| **Gemini CLI** | 需在 `.gemini/settings.json` 里指定（见下）|
| **RooCode / Kilo Code** | 支持 |
| **goose / opencode** | 支持 |
| **Amp / Jules / Factory / Phoenix / UiPath** | 支持 |

### 需要一行适配的

**Gemini CLI** — `.gemini/settings.json`：

```json
{
  "context": { "fileName": "AGENTS.md" }
}
```

**Aider** — `.aider.conf.yml`：

```yaml
read: AGENTS.md
```

**Claude Code** — 用 `CLAUDE.md`，让它引用 `AGENTS.md` 即可：

```bash
# 在项目根执行
echo '本项目的 Rust 编码规范见 @AGENTS.md' > CLAUDE.md
```

或者用软链接：

```bash
ln -s AGENTS.md CLAUDE.md      # macOS / Linux
mklink CLAUDE.md AGENTS.md     # Windows（需开发者模式或管理员）
```

---

## 环境恢复脚本（验证层）

换机器、重装系统、或者环境被搞坏了 —— 跑一个脚本恢复。

### Windows

```powershell
# 默认：自动选最快镜像，装到 %USERPROFILE%\Rust
powershell -ExecutionPolicy Bypass -File .\setup-rust.ps1

# 自定义位置和镜像
.\setup-rust.ps1 -InstallRoot "E:\Dev\Rust" -Mirror rsproxy

# 快速检查模式
.\setup-rust.ps1 -SkipVerify -SkipPsReadLine
```

### macOS / Linux

```bash
chmod +x setup-rust.sh
./setup-rust.sh

./setup-rust.sh --mirror rsproxy
./setup-rust.sh --root "$HOME/.local/rust" --mirror none
./setup-rust.sh --skip-verify
```

### 脚本会做什么

| # | 步骤 |
|---|---|
| 1 | 确定安装位置（Windows 默认 `%USERPROFILE%\Rust`；Unix 默认沿用 `~/.rustup` + `~/.cargo`，即不改动）|
| 2 | **实测各镜像延迟**，自动选最快（`tuna` / `rsproxy` / `ustc`）|
| 3 | 设置 `RUSTUP_HOME` / `CARGO_HOME` / `RUSTUP_DIST_SERVER`，修正 PATH |
| 4 | 安装或修复 rustup（含损坏工具链的强制重装）|
| 5 | 装 stable 工具链 + `clippy` + `rustfmt` |
| 6 | 写 crates.io 镜像配置（`-Mirror none` 时则移除）|
| 7 | Windows 额外检查 PSReadLine 版本（VS Code shell integration 需要 2.1+）|
| 8 | **端到端验证**：新建临时项目 → 拉真实依赖 → `build` / `clippy` / `fmt` / `test` |

**幂等**：已装好的部分会跳过，可以反复运行。

### 两个平台的坑（脚本里都处理了）

| 坑 | Windows | macOS / Linux |
|---|---|---|
| 脚本编码 | **必须带 UTF-8 BOM** —— 否则 PS 5.1 按 GBK 读，中文注释变乱码并导致语法错误 | **必须无 BOM** —— 否则 `bad interpreter` |
| 原生命令 | `$ErrorActionPreference='Stop'` + `rustup` 写 stderr → **脚本直接中止**（已用 helper 隔离）| — |
| `set -e` 陷阱 | — | `[ 条件 ] && 命令` 在条件为假时整行返回非零 → **脚本退出**（已全部改成 `if`）|
| 配置文件编码 | `config.toml` 必须**无 BOM**（PS 的 `Set-Content -Encoding UTF8` 会加 BOM）| 无此问题 |
| PATH 修改 | 改前**自动备份**原 User PATH 到 `%TEMP%` | 默认不改，仅提示需手动加 shell 配置 |

---

## 为什么这样设计：三层架构

换 Agent 时，这三层的可移植性**完全不同**：

| 层 | 内容 | 换 Agent 后 |
|---|---|---|
| **验证层** | Rust 工具链、镜像、`cargo config.toml`、环境变量 | ✅ **100% 复用**（与 Agent 无关）|
| **指令层** | 本文件（`AGENTS.md`）| 🔄 **内容可复用**，格式需适配 |
| **能力层** | 斜杠命令、MCP server、hooks | ❌ 各家语法不同，需重写 |

**结论**：把精力放在**验证层**（让 Agent 能真的跑 `cargo check`）和**指令层**（`AGENTS.md`），
而**不要投资能力层**——那是绑定特定 Agent 的，换一家就作废。

本套件的 `AGENTS.md` 就是这个思路：**只写 Agent 无关的内容**
（语言惯用法、错误处理、探索流程、验证纪律），不依赖任何一家特有的语法。

---

## 相比「原版」修掉了什么

这份 `AGENTS.md` 是从 GitHub Copilot 版配置转换来的，转换时修掉了两类**会让 Agent 说假话**的问题：

### 1. 机器假设 → 自检

| 问题 | 原写法 | 现写法 |
|---|---|---|
| 工具链 | 「本机 Rust 工具链已就绪，编译很快」 | 「**先跑 `--version` 确认**；失败就明说，不要假装能编译」|
| edition | 「设置 `edition = "2024"`（本机 rustc 1.98.1 支持）」| 「**先跑 `rustc --version` 确认**，再选对应 edition」|

> 换到没装 Rust 的机器后，原写法会让 Agent **以为能编译**，于是跳过验证、输出"应该没问题"。

### 2. 硬编码路径 → 探测

| 问题 | 原写法 | 现写法 |
|---|---|---|
| crate 源码位置 | `~/.cargo/registry/src/...` | **先探测** `$CARGO_HOME`，或用 `cargo metadata` 问 cargo |

> ⚠️ 这个坑**必然触发**：如果 `CARGO_HOME` 被改写过（比如装到 D 盘），
> 或在 Windows 上用 Git Bash（Kimi Code / Claude Code 默认 shell），
> `~/.cargo` 会指向一个**空目录** —— Agent 找不到源码，然后得出错误结论。

---

## 与 Copilot 用户级配置的关系

你现在的 Copilot 用户级配置在：

```
%APPDATA%\Code\User\prompts\
├── rust.instructions.md     ← 全局生效（applyTo: **/*.{rs,toml}）
└── rust-*.prompt.md          ← 5 个斜杠命令
```

两者的分工：

| | 用户级 `rust.instructions.md` | 项目级 `AGENTS.md` |
|---|---|---|
| 生效范围 | 你所有项目（任何机器，随账号同步）| 只有这个项目 |
| 团队共享 | ❌ 只有你自己 | ✅ 提交进 Git，团队共用 |
| 子目录覆盖 | ❌ 不支持 | ✅ 支持（就近优先）|
| 其他 Agent | ❌ 只有 Copilot 认 | ✅ 通用 |

**建议**：两个都留着 —— 用户级兜底（换项目也有保障），项目级叠加（团队共享 + 更细粒度）。

---

## 数据来源

- AGENTS.md 规范：https://agents.md/
- Kimi Code CLI 文档：https://moonshotai.github.io/kimi-code/en/configuration/config-files
- 托管方：Agentic AI Foundation（Linux Foundation）
