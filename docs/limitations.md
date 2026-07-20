# Known Limitations

shell-json 是一个纯 Bash 实现的 JSON 库，在设计上做了明确的取舍。本文档列出已知的局限性和边界条件。

---

## 设计层局限

### 1. 无流式/SAX 解析

整个 JSON 必须先完整解析为 AST，之后才能查询或序列化。不支持逐行或增量处理：

```bash
# 必须这样做
root=$(json.parse "large.json")
result=$(json.query "$root" '$.key')

# 不支持
json.parse_stream "large.json" | while read -r event; do ... done
```

**影响**：对于数百 MB 以上的 JSON 文件，解析阶段就会消耗全部内存（AST 文件 + 临时数据）。

### 2. 只读查询接口

AST 解析后不可修改。不支持添加/删除/更新节点：

```bash
# 不支持
json.set "$root" '$.key' '"new_value"'
json.delete "$root" '$.items[0]'
```

**替代方案**：修改数据需要重新解析整个 JSON。

### 3. 无 JSON Schema 验证

没有 `json.validate` 功能。类型检查、必填字段校验等需要自行实现。

### 4. 单线程 / 单会话限制

PID 文件 (`/tmp/.shell-json-ast-dir.$$`) 采用「后写者覆盖」策略。同一 shell 进程中同时进行多个 `json.parse_string` 调用（非串行）会导致 PID 文件指向错误的 AST 目录：

```bash
# ❌ 问题示例：第二个 parse 覆盖 PID 文件
p1=$(json.parse_string '{"a":1}')
p2=$(json.parse_string '{"b":2}')   # 覆盖 PID 文件
json.dump "$p1"                      # 可能读到错误目录
```

**正确用法**：每次 `json.parse`/`json.parse_string` 之后，完成所有操作再开始下一次：

```bash
p1=$(json.parse_string '{"a":1}')
json.dump "$p1"
json.free "$p1"

p2=$(json.parse_string '{"b":2}')
json.dump "$p2"
json.free "$p2"
```

### 5. 文件型 AST 的 I/O 开销

每个 AST 节点存储为一个独立文件。对 10,000 节点以上的 JSON，每次节点访问都是一次系统调用：

```
/tmp/shell-json.XXXXXX/nodes/
  0000001    ← 每次 ast_get_type / ast_get_value 都是 open + read + close
  0000002
  ...
```

**影响**：深度嵌套的复杂 JSONPath 查询（如 `$..author` 递归搜索）可能比 `jq` 慢 10-100 倍。对于典型配置文件级 JSON（<1000 节点），性能可接受。

### 6. 序列化全量在内存

`writer.sh` 在输出之前会将完整 JSON 字符串构建在内存中。对于极大 JSON（100MB+），可能导致 OOM：

```bash
output=$(json.dump "$root")   # 整个字符串在内存中
```

---

## 环境兼容性

### 7. 仅限 Bash

| Shell | 状态 |
|-------|------|
| **bash 4.3+** | ✅ 完全支持 |
| **zsh** | ⚠️ 部分支持（见下） |
| **sh** | ❌ 不支持 |
| **dash** | ❌ 不支持 |
| **bash < 4.3** | ❌ 不支持（缺少 `local -n` nameref） |

测试矩阵：GitHub Actions 在 bash 4.3 / 4.4 / 5.0 / 5.1 / 5.2 上全部通过。

### 8. zsh 兼容限制

zsh 下 `source src/json.sh` 已修复，核心解析功能可用。但以下场景在 zsh 下**不工作**：

- 部分直接调用 `_q_*` 内部函数的测试（未经 `query_execute` 包装）
- Unicode 代理对（surrogate pair）解码
- 极少数数值格式化边界情况
- `$[0]` 在双引号内会被 zsh 当作算术展开，必须用单引号

```bash
# ✅ zsh 下正确
json.query "$root" '$[0]'

# ❌ 错误：zsh 会将 $[0] 当作算术展开
json.query "$root" "$[0]"
```

### 9. macOS 兼容性

macOS 自带的 Bash 3.2 不支持。需要通过 Homebrew 安装 Bash 4.3+：

```bash
brew install bash
```

---

## 运行时问题

### 10. 临时文件清理

`ast_init` 在 `/tmp/` 下创建临时目录。正常情况下 `json.free` 会清理。但如果进程被 `kill -9` 或系统崩溃，会留下脏文件：

```bash
# 正常使用 → 自动清理
json.free "$root"

# 进程崩溃后 → 手动清理
rm -rf /tmp/shell-json.*
rm -f /tmp/.shell-json-ast-dir.$$
```

建议将 `TMPDIR` 环境变量指向一个可定期清理的目录（如系统重启后自动清空）。

### 11. 数字精度

数字以字符串形式存储在 AST 中，不会丢失精度。但比较运算受限于 Bash 的算术能力：

- 整数比较：支持 Bash 有符号 64 位范围（-2^63 ~ 2^63-1）
- 浮点数：JSON 中的浮点数字作为字符串保留，但过滤表达式中的数值比较使用 Bash 算术（整数）
- 超出范围的整数：能解析、存储和序列化，但过滤表达式中无法正确比较

### 12. 子进程与 `$()` 模式

`json.parse` 和 `json.parse_string` 设计为通过 `$()` 命令替换调用。这会创建一个子 shell：

```
$(json.parse_string '...')
        │
        ├── subshell ── ast_init ── 创建 AST 目录 + PID 文件
        │              ├── parser_parse ── 解析 JSON
        │              └── printf root_id ── 输出到 stdout
        │
        root_id ◄────────── 捕获输出
```

为了跨子 shell 边界传递 `_AST_DIR`，库使用 PID 文件。这是可靠的，但增加了一次文件读取。

### 13. 错误状态的跨子 shell 传递

与 `_AST_DIR` 相同，`json.last_error` 获取的错误信息也通过 PID 文件跨子 shell 传递。在 `$(...)` 外部调用 `json.parse_string`（不使用 `$()` 捕获）会导致错误状态覆盖。

### 14. 外部工具依赖

| 工具 | 用途 | 替代方案 |
|------|------|---------|
| `mktemp` | 创建临时目录 | POSIX 标准，所有 Linux/macOS 可用 |
| `base64` | 节点值编码（防换行/二进制） | GNU 和 BSD 实现均可处理 |
| `sed` | 值清理 | 仅用于 `$'\n'` → 字面换行转换 |

---

## JSONPath 局限

### 15. 过滤表达式能力受限

支持的比较运算符：`==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`

**不支持**：
- `@.length` 函数扩展（`$[?(@.length > 2)]`）
- 正则匹配（`$[?(@.name =~ /pattern/)]`）
- 计算值表达式（`$[?(@.price + 1 > 10)]`）
- 嵌套过滤（`$[?(@.items[?(@.price < 5)])]`）

### 16. Unicode 支持

- `\uXXXX` 转义序列正确解码
- 代理对（surrogate pairs）正确合并为单个 Unicode 码点
- 不执行 Unicode 规范化（`NFC`/`NFD`）
- 无效的 `\uXXXX` 序列（如代理对不完整）不会报错

---

## 性能参考（非正式）

以下数据基于典型配置文件（< 10KB / < 500 节点）。**非正式基准，仅供参考**：

| 操作 | shell-json | jq |
|------|-----------|-----|
| 解析 + 查询 | ~5-15ms | ~1-3ms |
| 深度递归查询 (`$..key`) | ~10-50ms | ~2-5ms |
| 序列化 | ~2-5ms | ~1ms |
| 启动开销 | ~2ms | ~10-20ms (JVM/工具启动) |
| 大文件 (1MB+) | 显著慢于 jq | 优 |

**结论**：shell-json 适合配置文件、API 响应的临时解析等轻量场景。大数据或高性能场景建议使用 `jq` 或其他原生工具。
