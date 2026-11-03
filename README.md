# zigregex

用 Zig 0.17 编写的小型正则表达式库，语法与匹配语义以 Python `re` 为准（与 PCRE 基本一致），无外部依赖。最初为 [typlint](https://gitee.com/graviton/typlint) 编写，以便规则可以直接照抄 Python 脚本里的正则。

## 支持的语法

- 字面量与转义：`\n \t \r \f \v \a`、`\xhh`、`\uhhhh`、`\Uhhhhhhhh`、八进制 `\0`、`\101`；
- `.`、字符类 `[...]`、`[^...]`、`\w \d \s` 及其否定 `\W \D \S`；
- 断言：`^ $ \A \Z \z \b \B`；
- 捕获组 `(…)`、非捕获组 `(?:…)`、命名组 `(?P<name>…)` / `(?<name>…)`；
- 分支 `|`；量词 `* + ? {m} {m,} {,n} {m,n}`，以及懒惰形式 `*?` 等；
- 前瞻 `(?=…)` `(?!…)`，定宽后顾 `(?<=…)` `(?<!…)`；
- 反向引用 `\1`、`(?P=name)`；
- 标志 `i m s`：编译选项、全局写法 `(?i)`（只能放在模式开头）、作用域写法 `(?i-s:…)`；注释 `(?#…)`。

不支持：原子组、占有量词、递归、条件子模式、`\p{…}`、`x`/`a`/`L` 标志。

许可证：AGPL-3.0，见 [LICENSE](LICENSE)。

语义细节与 Python 3.14 一致，例如：
- `$` 也匹配末尾换行之前的位置；
- `\Z` 只匹配文本末尾；
- `\B` 可以匹配空串；
- 迭代中遇到空匹配后的处理与 `finditer` 相同；
- 大小写折叠包括 `s`/`ſ`、`k`/`K`（开尔文符号）这类额外等价。

## 用法

添加依赖（会写入 `build.zig.zon` 的 `.url` 和 `.hash`）：

```sh
zig fetch --save=zigregex "git+https://gitee.com/graviton/zigregex.git#<commit>"
```

`build.zig`：

```zig
const regex = b.dependency("zigregex", .{ .target = target, .optimize = optimize }).module("regex");
exe.root_module.addImport("regex", regex);
```

代码：

```zig
const regex = @import("regex");

var diag: regex.Diagnostics = .{};
var re = try regex.Regex.compile(gpa, "(?P<user>\\w+)@(\\w+)", .{ .diagnostics = &diag });
defer re.deinit();

var m = try regex.Matcher.init(gpa, &re, .{}); // 可复用，避免每次分配
defer m.deinit();

if (try m.search(input, 0)) |hit| {
    _ = hit.group(re.groupIndex("user").?); // ?[]const u8
}
var it = m.iterator(input); // finditer
while (try it.next()) |hit| _ = hit.span(0);
```

- 位置是 UTF-8 字节偏移；匹配按码点进行，非法 UTF-8 按单字节处理。
- `Match` 指向 `Matcher` 内部的缓冲区，下一次调用后失效。
- `Matcher.Options.step_limit`（默认 1000 万）限制每次搜索的 VM 步数，超出时返回 `error.MatchLimitExceeded`。
- 编译失败返回 `error.InvalidPattern`，`Diagnostics` 中给出字节偏移和原因（措辞沿用 Python）。

## 实现

| 文件 | 内容 |
| --- | --- |
| `src/root.zig` | 对外 API：`Regex`、`Matcher`、`Match`、`Iterator` |
| `src/parse.zig` | 模式 → AST，报错条件参照 Python 的 `sre_parse` |
| `src/compile.zig` | AST → 字节码；计数量词展开，可空循环加进度检查 |
| `src/vm.zig` | 回溯 VM：显式栈加撤销日志；前瞻、后顾是原子的 |
| `src/CharClass.zig` | 字符类 |
| `src/unicode.zig` | `\w \d \s` 与大小写折叠查询 |
| `src/unicode_tables.zig` | 由 `tools/gen_unicode_tables.py` 从 Python 3.14（Unicode 16.0）生成 |

## 测试

```sh
zig build test                                   # 单元测试
zig build probe -Doptimize=ReleaseSafe           # 差分测试用的探针程序
uv run --no-project --python 3.14 python tools/regex_diff.py -n 40000 --seed 1
```

`tools/regex_diff.py` 随机生成覆盖上述语法的模式和输入，逐个比较 Python `re` 与本库给出的每个匹配、每个组的位置。Python 侧每个用例限时 2 秒，因为它没有步数上限，个别模式会陷入灾难性回溯。

已知差异：
- 嵌套量词，如 `((.*)+x)*`：Python 对单字符重复有快速路径，本库可能先触及步数上限，大约每 4 万个随机用例出现 0–1 次；
- 后顾中引用此前的组：Python 允许，本库报错。
