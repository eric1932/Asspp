# SAP 登录修复与验收记录

库层代码位于 `Packages/ApplePackage`，基于 ApplePackage 1.2.7 的提交
`28710fec47fa89dfdedf2bf47cc284a2334ddfdc`。应用通过本地 Swift package 引用接入，
库层和应用层分别提交，方便后续向上游提交库补丁。

## 已实现

- 读取 Bag 根节点或 `urlBag` 中的 SAP 版本、setup 和 certificate 地址；配置不完整或版本不支持时明确失败。
- 使用固定 Unicorn TCI 提交、静态 C 接口和 ipatool 的加载器与系统函数模拟；只构建 x86 客体，不使用 JIT。
- Apple 资源支持两个构建版本：即时下载版在设备获取并缓存；内置版在 CI 获取后作为 App 资源打包。两者都校验固定大小与 SHA-256；二进制不提交进 Git，内置 IPA 则包含这些文件。
- plist 只序列化一次，签名输入与 HTTP body 使用同一份 Data；签名 Base64 编码一次。
- 登录、验证码重试和 token 刷新使用相同签名路径；重定向保持 POST/body 并重新签名。
- 空响应 403、超时和签名错误结束当前尝试；保留 cookie、storefront、pod 和 Account 编码格式。
- 原生初始化与签名在后台串行执行；支持进度、取消和释放；认证日志隐藏凭据、cookie、token 和签名。

## 验证

新增 `ipa-bundled.yml` 和 `ipa-download.yml` 两个独立入口，共用 `ipa-build.yml`。
输出 Release 未签名 IPA、提交编号和 SHA-256。内置版资源不复制到设备缓存，损坏或缺失时不回退下载。

提交 `e555aefe394fe7eb6569658f0f886346b79dab52` 的两个版本均已构建成功：

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
