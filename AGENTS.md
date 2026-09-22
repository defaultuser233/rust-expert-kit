# Rust 专家工作准则

> **Agent 中立**：适用于所有读取 `AGENTS.md` 的编码 Agent —— GitHub Copilot、Kimi Code、
> Claude Code、OpenAI Codex、Cursor、Zed、Gemini CLI、RooCode、goose、opencode 等。
>
> **用法**：放到**项目根目录**。子目录可放自己的 `AGENTS.md` 覆盖父级（**就近优先**）。
> 冲突时：最近的 `AGENTS.md` 生效 > 上层 `AGENTS.md` > 用户在对话里的临时指令。

---

## 0. 最高优先级：先验证，后断言

**开工前必须先确认工具链可用**（换机器、新环境、CI 里同样适用）：

```bash
rustc --version && cargo --version && cargo clippy --version && cargo fmt --version
```

若任一命令失败（例如出现 `rustup could not choose a version of cargo to run`），
**先明确告知用户工具链不可用并给出修复方式**，不要假装能编译，
也不要凭想象写"应该能通过"：

```bash
rustup default stable
```

工具链确认可用后，下面的"必须验证"要求才成立。

- **禁止凭记忆断言** API 签名、crate 最新版本号、"某类型实现了某 trait"。查不到就说查不到。
- **改完 Rust 代码必须跑验证**，按代价从低到高：
  - `cargo check` —— 最低成本，先跑这个
  - `cargo clippy --all-targets -- -D warnings` —— 写完整功能后
  - `cargo test` —— 有测试时，必须跑
  - `cargo fmt` —— 收尾
- 报告结果时**贴真实命令输出**。没跑就说"未验证"，不要写"应该没问题"。

---

## 1. 语言惯用法（Idiomatic Rust）

### 所有权与借用

- 参数优先用借用：`&str` 而非 `String`、`&[T]` 而非 `&Vec<T>`、`&T` 而非 `&Box<T>`。
- 不要在结构体里存 `&'a str` 来"避免 clone"——除非确实是零拷贝解析场景，否则生命周期会污染整个 API。
- **不要为了通过借用检查器而无脑 `.clone()`**。先问：能否缩小借用范围？能否改参数为借用？
  能否用 `mem::take` / `split_off`？真的需要共享所有权才上 `Rc`/`Arc`。
- 需要内部可变性时，优先级：`&mut` → `Cell`（Copy 类型）→ `RefCell`（单线程）→ `Mutex`/`RwLock`（多线程）。
  **不要滥用 `RefCell` 绕过编译期检查**。

### 迭代器优先

- 禁止 `for i in 0..v.len() { v[i] }` 这类索引循环，改用迭代器。
- 用 `iter()` / `iter_mut()` / `into_iter()` 的语义差异要讲清楚：
  `iter()` 借出 `&T`，`into_iter()` 消费并移出 `T`。
- 链式组合 `.map().filter().collect()`，但**超过 5 步或含义复杂的链式要拆成命名函数**——
  可读性优先于"一行的爽感"。

### 类型设计

- Newtype 包装基本类型来防止参数顺序搞错：`struct UserId(u64)` 而非裸 `u64`。
- 能编译期表达的约束不要放到运行时：用类型状态、泛型、`PhantomData`。
- `Option<T>` 表示可能不存在，**不要用哨兵值**（`-1`、空字符串）。
- 派生 trait 时想清楚：`Debug` 几乎总是要；`Clone`/`PartialEq` 按需；
  **`Default` 要警惕**——如果"默认值"在业务上无意义，就不要实现它。
- `From`/`TryFrom` 优于自定义转换函数；为外部类型实现 trait 受孤儿规则限制时用 newtype。

### 字符串

- 拼接少量：`format!`；循环内拼接：`String::with_capacity` + `push_str`；复杂模板：`format!` 或专用库。
- 注意 `len()` 返回**字节数**不是字符数；按字符/字形遍历用 `chars()` / `.graphemes(true)`。

---

## 2. 错误处理

| 场景 | 方案 |
|---|---|
| 库 crate 对外 API | `thiserror` —— 定义具体错误枚举，让调用方能 match |
| 应用 / bin / 脚本 | `anyhow` —— `Result<(), anyhow::Error>` + `.context("...")` |
| 一次性原型 | 允许 `unwrap`，但要注释 `// TODO: 生产环境需处理` |
| 不可能失败 | 用 `expect("不变量说明：xxx")` 而非 `unwrap()` |

**硬性规则**

- **生产代码路径禁止裸 `unwrap()` / `expect()` 处理可预期失败**。
  （`Mutex::lock()` 的 poisoned 情况、`HashMap` 索引等除外）
- 库代码**禁止 `panic!`**（除文档明确说明的"契约违反"）；不要用 `panic!` 做控制流。
- 错误信息要**可操作**：写"配置文件 config.toml 第 12 行缺少 `port` 字段"，不要写"解析失败"。
- 保留错误链：`#[from]` / `.context()`，不要 `.map_err(|_| MyError::Failed)` 丢掉原始错误。
- 用 `?` 而非手动 `match ... { Ok(v) => v, Err(e) => return Err(e.into()) }`。

---

## 3. 并发与 async

- **先问是否真的需要并发**。很多"慢"是 I/O 模式问题，不是缺多线程。
- CPU 密集 → `rayon` 或 `std::thread`；I/O 密集 → `tokio`。
  **不要在 async 运行时里跑阻塞代码**。
- 在 async 里必须调阻塞 API 时，用 `tokio::task::spawn_blocking`。
- **async 函数里不要跨 `.await` 持有 `MutexGuard`**（std 的 `Mutex`）。
  要么缩短作用域，要么用 `tokio::sync::Mutex`。
- 需要跨线程共享时，`Arc<T>` + `T: Send + Sync`。
  看到 `Rc<RefCell<T>>` 出现在多线程代码里就是 bug。
- 优先用 channel（`mpsc`、`crossbeam`）传递所有权，而非共享可变状态。
- 死锁预防：多把锁时**固定加锁顺序**，并写进注释。

---

## 4. unsafe 与性能

- `unsafe` 是**最后手段**。写之前必须先说明：为什么安全抽象做不到？
  安全抽象的代价具体是多少（benchmark 数据）？
- 每个 `unsafe` 块**必须**配 `// SAFETY:` 注释，逐条说明不变量为何成立。
- 不用 `unsafe` 实现"只是看起来更快"的代码。先 profile（`cargo flamegraph`、`perf`）再优化。
- 性能优化顺序：算法/数据结构 → 减少分配 → 减少拷贝 → 缓存友好 → 最后才是 unsafe。
- 热点路径避免：不必要的 `String` 分配、`format!`、重复 `clone`、
  `HashMap` 反复查找（改用 entry API 一次查找）。

---

## 5. Cargo 工作流

- 加依赖用 `cargo add <crate>`（会自动查最新版并写入），**不要手写版本号**。
- 提到任何 crate 时，**先确认最新版本**：`cargo search <crate> --limit 1`
  或 `cargo add <crate> --dry-run`。
- 多 crate 项目用 **workspace**，共享 `Cargo.lock` 与依赖版本。
- 库的公开 API 都要有 `///` 文档注释，并写 `# Examples`
  （会被 doc test 执行，等于免费测试）。
- feature 要**叠加式设计**（`default` + 可选增强），不要搞互斥 feature。
- 选 `edition` 前**先跑 `rustc --version` 确认真实版本**
  （`edition = "2024"` 需要 Rust 1.85+；更老的工具链用 `"2021"`）。
  **不要照抄版本号。**

---

## 6. 读第三方 crate 的源码

### 为什么优先读磁盘上的源码

网上的 API 文档、博客、以及模型自己的记忆，都可能对应**别的版本**。
而 `cargo fetch` 之后，你所依赖的那个版本就静静躺在磁盘上 —— 读它，答案不会错。
**这是所有查证手段里最可靠的一种。**

### 先定位：源码在磁盘的哪个位置

不要写死路径。`CARGO_HOME` 是用户可配的（Windows 上常被改到数据盘），
Git Bash / MSYS 环境下 `~` 的展开也可能与预期不符。**让 cargo 自己回答**：

```bash
cargo metadata --format-version 1 | tr ',' '\n' | grep manifest_path
```

```powershell
cargo metadata --format-version 1 | Select-String manifest_path
```

每一行输出是一个 `Cargo.toml` 的绝对路径，形如
`<某个前缀>/registry/src/<crate>-<version>/Cargo.toml`。
那个**前缀**就是所有依赖的源码根。输出为空 → 依赖尚未下载，先跑 `cargo fetch`。

> 备选：直接读环境变量。Bash 用 `echo "${CARGO_HOME:-$HOME/.cargo}"`；
> PowerShell 用 `"$env:CARGO_HOME"`（为空时回退到 `"$env:USERPROFILE\.cargo"`）。

### 再定向：按「想回答什么问题」决定读哪里

不要从第一行读到最后一页。先想清楚目标，再定点查找。

第一次接触一个陌生的 crate，建议**先建立整体印象** —— 扫一遍 `Cargo.toml`（它需要什么、提供什么开关）
和 `src/lib.rs`（它导出什么）—— 再按下面的表定点深入。

**第一站：`Cargo.toml`**

| 想回答的问题 | 该看哪 |
|---|---|
| 支持的最低 Rust 版本（MSRV） | `rust-version` 字段 |
| 能否用于裸机 / 嵌入式 | 有没有 `no_std`、`std` feature |
| 它依赖了谁（答案可能在下游） | `[dependencies]` |
| 有哪些可选能力，默认开哪些 | `[features]` |
| 元信息（版本、仓库、许可证） | 顶部字段 |

**第二站：按问题找代码**

| 想回答的问题 | 该读的位置 |
|---|---|
| 这个 crate 对外提供了什么 | `src/lib.rs` 里的 `pub mod` / `pub use` / `pub fn` |
| 这个结构体/枚举长什么样 | grep `struct <名>` / `enum <名>` |
| 这个 trait 定义了哪些能力 | grep `trait <名>` |
| 哪些类型实现了它 | grep `for <类型名>` |
| 这个类型有哪些方法 | grep `impl <类型名>` |
| 某个行为的具体算法 | 先按上表定位到类型，再顺着方法体往下读 |

定位模块时留意：Rust 允许两种文件组织 —— 独立文件 `foo.rs`，或目录加清单 `foo/mod.rs`。
2018 edition 之后常见 `foo.rs` 与 `foo/` 目录并存，子模块收在 `foo/` 中。

### 卡住了：三种「找不到」及其解法

| 现象 | 原因 | 解法 |
|---|---|---|
| grep 不到这个符号 | 它从子模块 re-export 出来了 | 在 `src/lib.rs` grep 这个名字，看 `pub use` 指向哪 |
| 完全不在这个 crate 里 | 它只是转发上游 | 读本 crate 的 `Cargo.toml`，找到同名依赖，回到「先定位」重新找 |
| 名字该在却搜不到 | 由宏生成 | 搜宏名本身，或看 `build.rs` |

### 引用时的格式

给出你读到的代码时，**路径必须是探测到的绝对路径，并且带上行号范围**：

```
C:\Users\you\.cargo\registry\src\index.crates.io-xxxx\serde-1.0.229\src\de\mod.rs:120-165
```

先给证据，再给结论。不要写 `~/.cargo` 这类未展开的路径。

---

## 7. 回答格式要求

- **先给结论，再给代码，最后给理由**。不要长篇铺垫。
- 代码用**完整可编译**的形式，包含必要的 `use` 语句；不要用 `...` 省略关键部分。
- 涉及版本敏感的 API 时，**明确写出适配的 Rust 版本 / crate 版本**。
- 讲概念时用**对比表格**（❌ 不要这样 / ✅ 这样做），比大段文字有效。
- 不确定的地方**直接说不确定**，并给出验证方法（跑什么命令、看哪个文件）。
- 中英混排约定：`trait` 首次出现写「特质（trait）」并在括号内保留原词，后文直接用 `trait`。
  中文 Rust 社区普遍这么用，不必强行全译。
