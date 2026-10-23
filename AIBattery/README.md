# AIBattery

一个从零实现的原生 macOS 电池充电管理工具，功能与交互对齐 AlDente Pro 1.39.x（九个设置面板 + 仪表板 + 菜单栏弹窗），  
**不包含任何 AlDente 的代码或资源文件**，UI 与 SMC 逻辑均为独立实现。

- 通用二进制：`arm64` + `x86_64`（Intel 与 Apple Silicon 同一份包）
- 最低系统：macOS 12.0 Monterey，向上兼容至当前 macOS
- 无第三方依赖、不联网；既有 **Xcode 工程**（双击即可编译运行），也保留纯命令行 `build.sh`

```
AIBattery/
├── AIBattery.xcodeproj/           Xcode 工程（共享 Scheme：AIBattery）
├── Tools/generate_xcodeproj.py    工程生成器（增删源文件后重跑即可）
├── Sources/
│   ├── Core/
│   │   ├── SMC.swift              AppleSMC 用户客户端（80 字节负载，逐字段偏移写入）
│   │   ├── Battery.swift          IOKit 电池 / 适配器 / PowerTelemetry 遥测
│   │   ├── PowerSampler.swift     IOReport 动态加载（不可用时返回 nil，不猜数）
│   │   ├── ChargeController.swift 充电能力探测 + 特权助手客户端
│   │   ├── AppState.swift         状态机、控制循环、定时任务、校准、持久化
│   │   ├── Models.swift / Theme.swift
│   ├── UI/                        仪表板、九个面板、菜单栏弹窗、功率流、图表
│   ├── main.swift
├── Helper/main.swift              以 root 运行的守护进程（唯一能写 SMC 的进程）
├── Resources/Info.plist, AppIcon.icns
└── build.sh                       纯命令行构建（无 Xcode 也可用）
```

## 用 Xcode 构建

```bash
open AIBattery.xcodeproj
# 选中 Scheme「AIBattery」→ ⌘R
```

工程里有两个 Target：

| Target | 类型 | 说明 |
| --- | --- | --- |
| `AIBattery` | macOS App | 主程序，`Resources/Info.plist`，`LSUIElement` |
| `AIBatteryHelper` | Command Line Tool | 特权守护进程，产物名 `com.aibattery.helper` |

`AIBattery` 依赖 `AIBatteryHelper`，并通过 **Copy Files（Destination: Wrapper，Path: `Contents/Library/Helper`）**
把它嵌进 `AIBattery.app/Contents/Library/Helper/`，同时勾选 `Code Sign On Copy`。

工程设置要点：

- `ARCHS = arm64 x86_64`、`ONLY_ACTIVE_ARCH = NO`（Release），Debug 只编当前架构以加快迭代
- `MACOSX_DEPLOYMENT_TARGET = 12.0`、`SWIFT_VERSION = 5.0`
- 签名：`CODE_SIGN_IDENTITY = "-"`（Sign to Run Locally），**不需要开发者账号**；分发时改成自己的 Team 即可
- 工程文件由 `Tools/generate_xcodeproj.py` 生成，UUID 稳定；新增 `.swift` 后跑一次脚本即可同步

命令行等价构建：

```bash
xcodebuild -project AIBattery.xcodeproj -scheme AIBattery -configuration Release \
           -derivedDataPath build/xcode build
# 产物：build/xcode/Build/Products/Release/AIBattery.app
```

## 不用 Xcode 也能构建

```bash
./build.sh            # 产物：build/AIBattery.app
open build/AIBattery.app
```

`build.sh` 直接用 `swiftc` 分别编译两个架构再 `lipo` 合并，只依赖 Command Line Tools，
适合 CI 或没有装 Xcode 的机器。

调试参数：

```bash
AIBattery.app/Contents/MacOS/AIBattery --panel chargeControl   # 直接打开某个面板
AIBattery.app/Contents/MacOS/AIBattery --popover               # 以独立窗口预览菜单栏弹窗
```

## 数据来源（全部实测核对，无估算）

| 界面字段          | 来源                                                                                       | 本机实测值                                          |
| ------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------- |
| 电池电量 / 硬件电量   | `AppleSmartBattery.CurrentCapacity`、`AppleSmartBatteryPack.StateOfCharge`                | 80%                                            |
| 电池充电（mAh）     | `AppleSmartBatteryPack.BatteryData.AppleRawCurrentCapacity`                              | 4285 mAh                                       |
| 最大容量          | `BatteryData.AppleRawMaxCapacity`（回退 `FullChargeCapacity`）                               | 5420 mAh                                       |
| 设计容量          | `BatteryData.DesignCapacity`                                                             | 6075 mAh                                       |
| 健康度           | `最大容量 / 设计容量`，四舍五入                                                                       | 89%                                            |
| 循环次数          | `CycleCount`                                                                             | 153                                            |
| 电压 / 电流 / 功率  | `Voltage`(mV)、`Amperage`(mA)、乘积                                                          | 12.16 V / 0.00 A / 0.00 W                      |
| 电池温度          | SMC `TB0T`（`flt`，℃；与系统显示一致）                                                              | 32.9 ℃                                         |
| 系统负载          | `PowerTelemetryData.SystemLoad` (mW)                                                     | 13.1 W                                         |
| 适配器实测电流/电压/功率 | `SystemCurrentIn`、`SystemVoltageIn`、`SystemPowerIn`                                      | 0.65 A / 20.18 V / 13.14 W                     |
| 适配器额定         | `AdapterDetails`：`Current`、`AdapterVoltage`、`Watts`、`Name`、`Manufacturer`、`SerialString` | 4.79 A / 20 V / 96 W / 96W USB-C Power Adapter |
| 风扇转速          | SMC `F0Ac`                                                                               | 2326 RPM                                       |

核对方式：`ioreg -rn AppleSmartBattery`、`system_profiler SPPowerDataType`、`pmset -g batt`、直接读取 SMC 键，  
四者交叉一致。所有单位换算写在 `Battery.swift` 中（mV→V、mA→A、mW→W）。

**SoC / 显示功耗**：需要 IOReport 的 Energy Model 计数器。本机 macOS 版本对普通用户只返回 0 值，  
因此界面显示 `--`，不会用 `系统负载 − 其他` 之类的差值去编造数字。

## 仪表板新增卡片

| 卡片 | 数值 | 数据来源 |
| --- | --- | --- |
| 耗电量 | 当前功耗，一位小数 | 插电时 `PSTR`（整机消耗），放电时 `电压 × |电流|`（电池输出） |
| 耗电量 · 副标题 | 剩余 X 小时 Y 分 | 见下方算式；插电时改为「已接电源 / 充电中 / 充满约…」 |
| 最大容量 | 健康度 % + `5424 / 6075 mAh` | `BatteryData.FullChargeCapacity` ÷ `DesignCapacity` |

**剩余时间怎么算**

```
已存能量 Wh = 剩余容量 mAh ÷ 1000 × 电压 V
剩余时间 h  = 已存能量 Wh ÷ 当前功耗 W
```

实测（Mac14,9）：`4077 mAh ÷ 1000 × 12.068 V = 49.20 Wh`，当前 11.1 W → **4 小时 26 分**。
`TimeRemaining` / `AvgTimeToEmpty` 在这台机器上恒为 `65535`（无效值），所以不用它们。

插电时电池并非能量来源，`总能量 ÷ 当前功耗` 描述的不是「还能用多久」，因此卡片改为显示充电侧信息，
不做无意义的换算。耗电量本身在插电时展示整机消耗（`PSTR`），因为此时电池不输出功率。

## 功率流动画

仪表板与菜单栏弹窗共用一套 `PowerFlowView`（`Sources/UI/PowerFlowView.swift`）。

**版式（对齐 AlDente 的 Sankey）**

```
[ 源功率卡 ] [MacBook] [ 色带扇形 ] [显示]
 输入功率                          [SoC]
 11.1 W                           [其他]
```

- **源功率卡**用中性底色，颜色只出现在左上角那个小图标上。试过两种强调方式都被否掉：
  整块金/绿渐变（色块太重）、左侧 3 pt 彩色竖条（看起来像一条孤立的线）
- **MacBook 与源卡完全同尺寸**：同宽（142 pt）、同高、同圆角（14 pt）、同三行结构
  （图标+名称 / 瓦数 / 状态）。两块等大的面板构成"输入 → 本机消耗"的主轴，色带从右侧面板边缘扇出；
  只靠一个浮空的小图标做中转，会让中间这张卡显得很空
- **色带从笔记本右侧的窄颈扇出**，右端接入各自的节点中心；粗细表达功率
- 瓦数用**同一列**打印在色带上（距右侧节点 32% 处），多个分支不会互相错位
- 功率为 0 的分支整条隐藏（例如未充电时的电池），与 AlDente 一致
- 顶部指标条图标按部件配色：适配器橙、MacBook 蓝、电池绿、SoC 紫、显示蓝、USB 灰

**为什么去掉了所有画框**

原先在第 4 段套了一个圆角矩形边框，本意是给扇形一个"舞台"。但卡片左侧是满高的功率块，
右侧是三块节点，中间再放一个边框盒子，画面就被切成三个高度互不相干的区块——这正是"不协调"的来源。
中间那层极淡的渐变托底也有同样的问题：它的上下边界仍会显出一条浅色横带。现在**完全没有底板**，
色带本身就是画面内容，三个区块统一在**同一条等高带**里：功率卡高度 = 节点列高度，
MacBook 节点与右侧节点同一尺寸、在带内垂直居中。

**视觉映射（全部由瓦数驱动）**

| 元素 | 映射关系 |
| --- | --- |
| 出口束带 | 等高带的 17%，按分项占比切分 → 扇形窄颈 |
| 色带厚度 | 与占比成正比，上限为节点高度的约 82%（宽分支填满、细分支成线） |
| 节点尺寸 | 右侧 **固定** 44/40 pt、间距 8/7 pt；左侧源卡与 MacBook 面板等高、等宽 |
| 纵向留白 | 视图内 `padY = 2`（卡片本身已有 12 pt padding，再叠加就变成 24 pt 死白） |
| 粒子 | 彗星式：亮核 + 光晕 + 两道拖尾；数量 `2 + 6 × min(1, W/14)` |
| 速度 | `0.30 + min(0.55, W/40)` 周/秒 |
| 口径 | 所有数字统一 `%.1f`，由 `PowerFormat.watts` 单点输出 |

节点尺寸固定是有意为之：早先让节点高度跟随占比，结果 5.9 W 的「其他」变成一根 130 pt 高的空条，
图标和文字浮在中间；MacBook 也被拉长成一根柱子。现在功率只由**色带粗细**表达，节点始终是等大的方块，
一行看过去是整齐的图标列，任何分支都不会因为比例失衡而变形。

**数字为什么不再乱跳**

SMC `PSTR` 每秒采样一次，相邻两次能差 1–2 W；直接显示会让数字持续抖动。现在分三层处理：

1. **几何**用 30 fps 指数平滑（τ≈0.55 s），色带和节点高度连续变化；
2. **文字**只在每 2 秒发布一次，且发布的是这 2 秒的**均值**，再量化到 0.1 W、加 0.2 W 死区——
   落在四舍五入边界上的值不会反复翻转；
3. **「其他」**直接用屏幕上已经发布的总量和分项相减，因此**用户看到的数字永远加得闭合**
   （例：`≈1.1 + ≈1.9 + 22.8 = 25.8`，与左侧输入功率逐位一致）。

SoC / 显示的估算输入（CPU 占用率、屏幕亮度）另有 6–8 秒的指数平滑，避免估算值本身在抖动。

**数据质量：实测 / 估算 / 不可用**

每一项都带质量标记，界面用三种方式区分，绝不把模型输出伪装成传感器读数：

| 部件 | 来源 | 质量 | 说明 |
| --- | --- | --- | --- |
| 电源适配器输入 | **SMC `PSTR`（约 1 Hz 实时）** | 实测 | 与 `PSTR(t+1) == PDTR(t)` 互为先后采样 |
| MacBook 总功耗 | `PSTR − 电池充电功率` | 实测 | 电池未充电时与输入相等（物理上成立） |
| 1 分钟均值 | `PowerTelemetryData.SystemLoad` | 实测 | **60 秒快照**，仅作参考，不用于动画 |
| 电池充放电 | `Voltage × Amperage` | 实测 | 带符号，充电为正 |
| SoC | `powermetrics --samplers cpu_power` | 实测 | 仅当特权助手已安装（root）；取 `Combined Power (CPU + GPU + ANE)` |
| SoC | `1.2 W + 22.0 × CPU占用^1.25` | 估算 | 助手未安装时的回退 |
| 显示 | `0.6 W + 4.4 × 亮度^1.6` | 估算 | 亮度取自私有 `DisplayServicesGetBrightness`（与 AlDente 同一框架） |
| USB | 无数据源 | 不可用 | 不猜测 |
| 其他 | `总功耗 − 已知分项` | 残差 | 含估算误差，不计入实测 |

估算值的公式会写进悬停提示，「其他 → 功率数据源」卡片里也能看到每一项的当前状态（实测 / 估算 / 不可用）。
**界面上不再用 `≈` 前缀标注估算**——一半的数字都带这个符号只会增加噪音，区分方式改由悬停提示与数据源卡片承担。
一旦某项有了实测来源（例如装好助手后的 SoC），`≈` 会自动消失，节点随之变成实测配色。

估算值还受**总量约束**：当 `SoC + 显示` 超过可用功率的 80% 时按比例缩放，保证「其他」不会被挤成 0，
悬停提示里会显示缩放系数。

**修掉的底层问题：SystemLoad 是 60 秒快照**

最早用 `PowerTelemetryData.SystemLoad` / `SystemPowerIn` 当作实时功率，界面会比其他工具低一半甚至更多。实测取证：

| 观测 | 结果 |
| --- | --- |
| `UpdateTime` 变化 | 每 **60 秒**才跳一次 |
| `SystemLoadAccumulatorCount` | 60 秒内只 +56，任何 10 秒窗口内 +0 |
| 8 × `yes` 结束后 12 秒 | `SystemLoad` 仍停在 29.80 W，`PSTR` 已回落到 14.28 W |
| 稳态对比 | `PSTR 14.72 W` == `SystemLoad 14.72 W`（完全一致） |

也就是说两者是**同一个物理量**，只是 `SystemLoad` 每分钟才刷新一次。界面若直接读它，负载一变就会整分钟地落后。

现在改用 SMC 的 `PSTR`（约 1 Hz）作为实时值，`SystemLoad` 降级为「1 分钟均值」显示在电池规格卡里。
`PSTR` 只在 Apple Silicon 上存在，Intel 机型自动回落到 60 秒快照，并在数据源卡片里标明。

**为什么不用 IOReport 的能量计数器**

这是 AlDente 用的那套 API（它 `dlopen("/usr/lib/libIOReport.dylib")`，调用 `IOReportCopyChannelsInGroup` / `CreateSamples` / `CreateSamplesDelta`）。
本机实测（Mac14,9 / macOS 27）：

- 177 个 `Energy Model` 通道都能枚举，`CPU Energy`、`GPU Energy`、`ANE0`、`DRAM0` 都在
- CPU 侧累计值**不递增**：`yes` 满载 75 秒，`EACC_CPU0` / `CPU Energy` 的 delta 精确为 0
- 只有 `GPU Energy` 在动，速率约 1.91×10⁹/s，量级更像时钟计数而非焦耳
- `IOReportCreateSamplesDelta()` 对所有 CPU 能量通道返回 0

因此在这台机器上无法把 IOReport 变成可信的实时瓦数，代码里保留了 `PowerSampler` 接口留待可用环境接入。

## 充电控制

运行时探测（不是按芯片型号硬编码），并把结果原样展示在「其他 → 充电控制状态」：

| 策略            | 条件     | 行为                                     |
| ------------- | ------ | -------------------------------------- |
| `BCLM`        | 键存在且可写 | 直接写入充电上限（Apple Silicon 的标准做法），放电也由它完成  |
| `CH0B`/`CH0C` | 键存在    | `0x00` 允许充电、`0x02` 禁止充电（Intel / T2 机型） |
| `CHIE`        | 键存在且可写 | 写 1/0 禁止/恢复充电，上限由守护循环按阈值维持             |
| 不可用           | 都不存在   | 界面明确提示，不做假动作                           |

本机（Mac14,9 / M2 Pro / macOS 27）实测：`BCLM`、`CH0B`、`CH0C`、`CH0I` 均不存在，  
只有 `CHIE`（`hex_`，可写）与 `MSLD`。因此默认走 `CHIE` + 守护循环，并在设置页展示原始键表。  
装好特权助手后，能力探测会改由 root 进程查询，以覆盖「某些键只有 root 可见」的情况。

控制循环（2 s 一次）依次处理：过热保护 → 校准状态机 → 航海模式/上限判定 → 仅在状态变化时下发写入。  
界面上的「充电中/已暂停」由 `IsCharging` 实测值决定，而不是由我们的意图决定。

## 特权助手

写 SMC 需要 root。`Helper/main.swift` 是一个 130 行的守护进程：

- 安装到 `/Library/PrivilegedHelperTools/com.aibattery.helper`，LaunchDaemon 常驻
- 只监听 `/var/run/com.aibattery.helper.sock`，`0600`，属主为安装者 UID；连接时用 `getpeereid` 校验对端 UID
- 接受 `ping / info / read / write / exec / socpower` 六种命令，`exec` 只允许 `pmset`、`killall`、`caffeinate`、`powermetrics`
- `socpower` 在 root 下调用 `powermetrics --samplers cpu_power`，把 `Combined Power (CPU + GPU + ANE)` 回传给 app，用于把 SoC功耗从「估算」升级为「实测」
- 安装需要一次管理员授权（`osascript ... with administrator privileges`），不做静默提权

未安装时应用照常显示全部数据与设置，只是无法真正改写 SMC，并在「其他」页给出安装入口。

## 功能覆盖

- 仪表板：功率流（适配器→MacBook→显示/SoC/电池/USB/其他）、电池规格、电池健康、适配器规格、电量与温度曲线、风扇、高功耗应用、校准入口
- 充电控制：充电上限、允许低于 80%、自动放电、航海模式与差异值、过热保护与温度上限、五段校准流程与上次校准时间
- 睡眠行为：三种睡眠充电策略 + 五项高级设置
- 能源使用：低电量模式策略、后台刷新、高功耗应用阈值、包含后台进程
- 定时设置：任务增删改、模板、自动补做、任务历史
- 捷径：12 个可用操作清单 + 跳转「快捷方式」
- 翻盖：启动显示、百分比、编辑模式、合盖相关开关
- 菜单栏：图标样式、主图标选项、四组可选菜单项、间距滑杆、预览
- 其他：程序坞图标、降低透明度、三种外观、MagSafe LED、调试导出、恢复默认、许可证、更新、开机自启、技术数据共享、充电控制诊断
- 菜单栏弹窗：限制/充满、带限位标记的电量条、状态说明、功率流、循环/温度/充满时间、底部按钮

## 已知限制

1. 未签名（ad-hoc）。分发给他人需要 Developer ID 与公证；特权助手同样需要正式签名才能长期免打扰。
2. 本机 `BCLM` 缺失，充电上限的**硬件级**生效取决于 `CHIE` 的实际语义，需在装有助手的真机上验证一次；  
   应用会如实显示实测充电状态，不会把「已下发」当成「已生效」。
3. SoC 在助手未安装时是估算值（带 `≈`）；显示功耗在两台机器上都只能估算（没有背光功率计数器）。
   IOReport 的 CPU 能量计数器在本机不递增，因此没有把它当作数据源（详见「功率流动画」一节）。
4. 快捷方式面板列出的是操作清单；未注册 App Intents（需要额外的 App Intents target 与 `Metadata.appintents`）。
5. 界面为简体中文（与参考截图一致），未做多语言。

