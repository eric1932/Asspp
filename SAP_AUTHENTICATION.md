# SAP 登录修复与验收记录

库层代码位于 `Packages/ApplePackage`，基于 ApplePackage 1.2.7 的提交
`28710fec47fa89dfdedf2bf47cc284a2334ddfdc`。应用通过本地 Swift package 引用接入，
库层和应用层分别提交，方便后续向上游提交库补丁。

## 已实现

- 读取 Bag 根节点或 `urlBag` 中的 SAP 版本、setup 和 certificate 地址；配置不完整或版本不支持时明确失败。
- 使用固定 Unicorn TCI 提交、静态 C 接口和 ipatool 的加载器与系统函数模拟；只构建 x86 客体，不使用 JIT。
- Apple 资源支持两个构建版本：即时下载版在设备获取并缓存；内置版在 CI 获取后作为 App 资源打包。两者都校验固定大小与 SHA-256；二进制不提交进 Git，内置 IPA 则包含这些文件。
- 每次认证尝试的 plist 只序列化一次，签名输入与 HTTP body 使用同一份 Data；重定向复用 body，后续尝试修改 attempt 后重新序列化并签名。签名 Base64 编码一次。
- 登录、验证码重试和 token 刷新使用相同签名路径；重定向保持 POST/body 并重新签名。
- 空响应 403、超时和签名错误结束当前尝试；保留 cookie、storefront、pod 和 Account 编码格式。
- 原生初始化与签名在后台串行执行；支持进度、取消和释放；认证日志隐藏凭据、cookie、token 和签名。

## 真机反馈后的修正（2026-09-10）

用户通过全能签 / AllinSign 侧载后的反馈显示两个不同阶段的问题：

- 内置版在两个账号上均因 CommerceKit 大小不匹配失败：实际 3,284,320 字节，
  固定值 3,271,840 字节。增加的 12,480 字节符合重签工具改写 Mach-O 的特征；
  尚未检查用户重签后的 IPA，因此不能将具体工具行为当作已确认事实。
- 即时下载版在无 2FA 的 CN 账号上完成 token 轮换；US 账号轮换返回凭据错误，
  用户未收到验证码。截图均来自“账户详情 / 轮换令牌”，无法证明重新输入当前密码的登录也失败。

提交 `45884535e7e146c3a302f52551e370df3d4f8c8b` 将内置资源改成单个
`SAPAssets.zip`。运行时只在内存解压，保留全部固定大小和 SHA-256 校验；不写入下载版缓存，
不接受被重签修改的文件。CI 对应用副本进行 ad-hoc 重签后再核对所有 SAP 字节。
这覆盖 Apple codesign 的重签路径；全能签的实际行为仍需用户在设备上复测。

账户详情新增“重新验证账户”：保留邮箱，重新输入当前普通登录密码和可选验证码。
验证成功才更新保存的账户，失败或取消不会先删除账户。验证码可在首次请求前主动填写，
不再需要先触发一次错误。轮换成功提示改为绿色。

认证请求从 `attempt=1` 开始，仅在首次收到 `failureType=-5000` 时继续一次
`attempt=2` 请求；后续请求重新签名，并保留 cookie、storefront、pod。重定向不消耗该次后续机会，
也不改变当次 body；403 和超时仍直接结束。这参考了
[固定版本 ipatool 的登录实现](https://github.com/majd/ipatool/blob/d5d0b56faf64e3fdef885d49e7928b390aadb6c7/pkg/appstore/appstore_login.go)，
不能据此保证 Apple 会发送验证码，也没有把普通凭据错误标为 2FA 挑战。

该接口使用普通账户密码，应用专用密码不受参考实现支持，见
[ipatool FAQ](https://github.com/majd/ipatool/wiki/FAQ#can-i-use-app-specific-passwords-to-login)。
不向 CI 提供真实账号、密码或验证码。

本机通过 7 项 Python 打包测试、Swift 语法、YAML 和脚本语法检查；未拉取 SwiftPM
依赖、原生库或 Apple 资源。首轮 CI 的 Go 资源测试和五个原生架构切片通过；
随后因新增 Swift 测试的初始化参数顺序错误停止。`cc06343` 已修正该测试。

以下最终结果针对提交 `cc063432eeccc0fb9479fb48baea6c643681fff0`，两个 workflow 均成功：

| 版本 | IPA 大小 | 构建与下载 |
| --- | --- | --- |
| 内置 ZIP 资源 | 39,711,265 字节 / 39.71 MB | [运行记录](https://github.com/eric1932/Asspp/actions/runs/34565995303)、[下载附件](https://github.com/eric1932/Asspp/actions/runs/34565995303/artifacts/10186486221) |
| 即时下载 | 18,234,266 字节 / 18.23 MB | [运行记录](https://github.com/eric1932/Asspp/actions/runs/34565995430)、[下载附件](https://github.com/eric1932/Asspp/actions/runs/34565995430/artifacts/10186340131) |

- 19 项离线 XCTest 在有、无原生库时均通过；两个版本各运行一遍。
- Go ZIP 加载器测试通过，原生库五个架构切片编译通过。
- 内置 ZIP 的真实资源初始化和虚构凭据签名认证两项集成测试通过。
- 两个 iPhone Release App 编译和最终 IPA 资源校验通过；本轮没有另行构建 macOS App。
- 对原始 CommerceKit 副本重签，确实改变字节；对新 App 副本重签，ZIP 及四个原始资源均保持有效。
  上传的是原始未签名 IPA，测试用 ad-hoc 签名没有进入交付附件。
- 附件中的 `BUILD.json` 确认提交与模式；内置版记录 `sap_resource_format: zip`。
  本机仅通过 HTTP Range 读取两份附件中的 735 / 968 字节元数据，没有下载 IPA。

```text
2cc8a2f669e59331652fca441e6346cadc69e0a6efac731b20c6c43c28d701b4  Asspp-bundled.ipa
fe0989e19f17c52690ca847e6487285354f9eba3d53c5d81419c042fecfe9226  Asspp-download.ipa
```

附件保留 7 天。解压附件获得 IPA 后重新签名安装；可通过“账户详情 → 重新验证账户”测试当前密码和验证码。
仍需真机确认全能签重签后的内置版，以及 US 账号的验证码推送、登录和 token 刷新。

## 历史验证

新增 `ipa-bundled.yml` 和 `ipa-download.yml` 两个独立入口，共用 `ipa-build.yml`。
输出 Release 未签名 IPA、提交编号和 SHA-256。内置版资源不复制到设备缓存，损坏或缺失时不回退下载。

旧提交 `e555aefe394fe7eb6569658f0f886346b79dab52` 的两个版本曾构建成功。
其中内置版包含原始 Mach-O 文件，已有上述侧载后损坏报告；以下附件仅保留为历史证据：

| 版本 | IPA 大小（十进制 MB） | 构建与下载 |
| --- | --- | --- |
| 内置资源 | 39,686,556 字节 / 39.69 MB | [运行记录](https://github.com/eric1932/Asspp/actions/runs/34449131853)、[下载附件](https://github.com/eric1932/Asspp/actions/runs/34449131853/artifacts/10141465847) |
| 即时下载 | 18,179,853 字节 / 18.18 MB | [运行记录](https://github.com/eric1932/Asspp/actions/runs/34449131859)、[下载附件](https://github.com/eric1932/Asspp/actions/runs/34449131859/artifacts/10141287409) |

内置版 IPA 增加 21,506,703 字节，约 21.51 MB；这是压缩包增量，Apple 资源展开后约 37.78 MB。
GitHub 附件是再封装的 ZIP，大小会与里面的 IPA 略有不同。附件保留到 2026-09-17 左右，
其中包含 `BUILD.json`、`SHA256SUMS.txt` 和资源来源说明。

- 两个 workflow 的 17 个离线 XCTest 在有、无原生库时均通过；原生库五个架构切片编译通过。
- Go 测试验证内置资源的只读加载、缺失、同长度损坏和取消；禁止网络访问。
- 内置版本另外通过真实资源初始化、虚构凭据签名认证两个集成测试（无真实账号）。
- 最终内置 IPA 的四个文件逐一通过固定哈希校验；即时下载 IPA 检查确认没有内置这些文件。
- 本机只运行 4 个新增 Python 离线检查、7 个已有准备脚本检查和语法检查；未安装依赖、下载 IPA 或 Apple 大型资源。

IPA SHA-256：

```text
9e423ced7080d3c0121970d7effbce1416cbfb9b0513c5d5266ef9818e19d258  Asspp-bundled.ipa
b79e81b41bdc333a316c3fa75681a6581066b5ea7408bee1fe1bee7e78be4a88  Asspp-download.ipa
```

以下是内置资源改动之前的历史验证记录。

[最终回归运行](https://github.com/eric1932/Asspp/actions/runs/34443603327)
针对提交 `d02f2f3`：

- 17 个离线 XCTest 用例通过；不加载原生库时和加载原生库时分别运行。
- macOS arm64/x86_64、iOS arm64、Simulator arm64/x86_64 原生库交叉编译通过。
- Swift → 静态 C ABI → SAP 握手 → 签名认证请求的联网测试通过。仅使用源码内固定的虚构账号。
- iOS/macOS App 编译与最终链接均通过；上述运行的全部 job 已成功完成。

[最初的引擎对照验证](https://github.com/eric1932/Asspp/actions/runs/34441535617)
显示：同一份虚构凭据，未签名返回空 HTTP 403，签名后返回 HTTP 200 和可解析的凭据错误。
它还覆盖了客体加载/系统模拟，以及 Swift C 接口的取消、释放。

本机仅增加约 0.5 MB 源码、测试和许可证文本，没有安装工具/runtime，没有下载 Apple 资源、
原生库或 SwiftPM 构建依赖，也没有启动 App 或模拟器。

## 2FA 判定的修正

真实测试发现：虚构账号同样返回空 `failureType` 和
`MZFinance.BadLogin.Configurator_message`，因此旧代码的“需要验证码”判断并不可靠。

现在这类响应表示 `credentialsRejected`。界面提供“输入验证码”按钮，由用户在收到验证码后主动展开；
错误验证码响应 `5005` 则保留输入框供修改。403、网络错误和签名失败不会自动展示验证码框。
这项调整来自实际响应，而不是放宽测试以掩盖签名失败。

## 后续真机验收

仍需在普通签名的 iPhone 和 macOS App 上人工验证：真实账号登录、收到验证码后的登录、错误验证码纠正、
token 刷新、登录后下载，以及首次资源准备的耗时、内存和取消行为。
HTTP 200 加上虚构账号的错误响应不代表真实账号已经登录成功；iOS 交叉编译不代表真机运行已经验证。

运行库构建和获取方式、固定来源、许可证声明见 `Resources/SAPRuntime/README.md`。
Unicorn/QEMU 保留 GPL 及组件许可证；应用的 MIT 声明不能替换这些许可证。许可证文本已随 Swift package 资源打包。

本机 GPG 签名缓存过期后，部分工作分支提交使用了未签名提交；Git 全局签名配置没有更改。
