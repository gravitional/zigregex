# 仓库协作说明

面向在本仓库工作的人与编码代理。功能与用法见 [README](README.md)。

## 环境

- Zig 0.17.0，本机在 `/data/yangmy/zig/zig`；文档见 https://ziglang.org/documentation/0.17.0/ 。标准库源码在 `/data/yangmy/zig/lib/std`，0.15 之后 I/O 接口（`std.Io`、`std.process.Init`）变化很大，不确定时直接查源码。
- Python 只用于生成表和差分测试，统一用 uv 管理的 3.14：`uv run --no-project --python 3.14 python ...`。系统 `python3` 是 3.8，Unicode 版本不同，不要用它比对。

## 语义基准

- 行为以 Python 3.14 的 `re` 为准。改动语法或匹配逻辑前，先在 Python 中确认预期结果；与 Python 不同的地方必须写进 README 的“已知差异”。
- 报错条件与措辞沿用 Python（`sre_parse`）。差分测试会比较“是否报错”，但不比较报错信息。
- `src/unicode_tables.zig` 是生成文件，不要手改。需要重新生成时运行 `ZIG=/data/yangmy/zig/zig uv run --no-project --python 3.14 python tools/gen_unicode_tables.py`，脚本会自动运行 `zig fmt`。

## 每次修改后

1. `zig build test`；
2. `zig fmt --check src tools build.zig`；
3. 差分测试，至少跑两个种子，必须零差异：
   ```sh
   zig build probe -Doptimize=ReleaseSafe
   uv run --no-project --python 3.14 python tools/regex_diff.py -n 40000 --seed 1
   ```
   新增语法时，同时扩充 `tools/regex_diff.py` 的生成器，让新语法被覆盖到。
4. 下游 [typlint](../typlint) 通过 `path` 依赖本仓库。改动公开 API 后，在 typlint 中运行 `zig build test`。

## 约定

- 公开 API 只从 `src/root.zig` 导出；其他文件是内部实现。
- 位置一律使用 UTF-8 字节偏移；匹配按码点进行。
- 匹配期间不得递归，只有前瞻、后顾例外，其深度受模式嵌套限制。新的回溯点和撤销记录都压入显式栈。
- 可能匹配空串的循环都要经过 `mark`/`progress` 进度检查。
- 提交信息用中文。
