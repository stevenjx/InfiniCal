# InfiniCal

macOS 电池工具，由 Infinity Computer 开发。两块能力：**测量真实电池健康**，以及**控制充电与散热**。

macOS 显示的「最大容量」是电量计固件的历史估算。长期浅充浅放后，这个数字会偏离电芯的真实状态。
InfiniCal 用一次受控的完整循环（满充 → 深度放电 → 满充 → 静置 → 回落），对电流做梯形数值积分，
算出这一轮真正搬运了多少电荷，从而得到真实满充容量、真实健康度、库仑效率与直流内阻。

散热侧直接读写 SMC 的风扇目标转速与模式，并提供基于温度的曲线控制。所有数据来自本机
IORegistry、SMC 与 IOHID，**没有估算、没有编造**：读不到就显示 `--` 并说明原因。

---

## 功能

### 电池校准

| 阶段 | 动作 | 完成判定 |
| --- | --- | --- |
| 1 预充 | 放开充电上限至 100% | 电量 ≥ 100% 且电流 ≤ 0.05 A |
| 2 受控放电 | 将放电目标设为 5/10/15/20%，可叠加 CPU 负载加速 | 电量 ≤ 目标值 |
| 3 复充 | 恢复满充 | 电量 ≥ 100% 且电流 < 0.15 A |
| 4 静置 | 保持满电 | 10 分钟 |
| 5 回落 | 放电至存储电量（默认 80%） | 电量 ≤ 存储值 |

测量在本地完成：

- **库仑计数** — 梯形积分 `∫I dt`，25 mA 零点死区，跨度 > 5 s 的采样段整段丢弃（休眠/卡顿不累加）
- **真实容量** — `放电电量 ÷ (起始电量 − 终止电量)`，输出 Wh 与 mAh
- **库仑效率** — `放电 Ah ÷ 复充 Ah`，反映自放电与老化
- **DCIR** — 电流阶跃 ≥ 1 A 且电压反向响应，中位数后 EWMA，物理区间约束 10–600 mΩ
- **健康度** — 本轮实测 65% + 固件先验 35%，多轮记录按 `exp(-0.35·n)` 衰减加权
- **电芯一致性** — 逐串电压与压差 ΔV

结束后自动导出 TXT 报告与 CSV 全量遥测（含每秒的电压/电流/功率/温度）到
`~/Library/Application Support/InfiniCal/Reports/`，记录写入同目录 `calibration.json`。

### 风扇控制

自动发现风扇数量（`FNum`），Apple Silicon 与 Intel 通吃。

| 模式 | 行为 |
| --- | --- |
| 自动 | 清除强制位，交回 SMC 的固件策略 |
| 自定义 | 滑块设定固定转速（步进 50 RPM） |
| 全速 | 目标转速 = `F{n}Mx` |
| 温度曲线 | 选定传感器，低于起始温度保持最低转速，达到满载温度线性升到最大转速 |

温度来源全部标注在界面上：CPU（IOHID `PMU tdie*` 平均，回退 SMC `Tp01/Tp05/Tp09/Tp0D`）、
电池（SMC `TB0T`）、固态硬盘（IOHID `NAND`）、GPU（SMC `Tg0B/Tg0C/Tg0H/TG0V`，仅当键真实存在）。
「显示全部传感器」列出 IOHID 报告的每一个温度服务，使用原始名称。

### 充电控制

充电限制、允许低于 80%、自动放电、航海模式、过热保护。按机型选择可用的充电控制键：
Apple Silicon 用 `BCLM`（上限）或 `CHIE`（禁止），Intel/T2 用 `CH0B`/`CH0C`。能力在运行时探测，
界面显示实际采用的是哪一种。

### 其他

仪表板（功率流 Sankey、四项趋势图、电池/适配器规格）、睡眠与能源、定时任务、外观。

---

## 数据来源

| 界面字段 | 来源 | 单位换算 |
| --- | --- | --- |
| 电量 / 硬件电量 | `AppleSmartBattery.CurrentCapacity`、`AppleSmartBatteryPack.StateOfCharge` | — |
| 最大容量 | `BatteryData.AppleRawMaxCapacity`（回退 `FullChargeCapacity`） | mAh |
| 设计容量 | `BatteryData.DesignCapacity` | mAh |
| 循环次数 | `CycleCount` | — |
| 电压 / 电流 / 功率 | `Voltage`、`Amperage`、`InstantAmperage` | mV→V、mA→A |
| 电池温度 | SMC `TB0T`（`flt`） | ℃ |
| 适配器 | `AdapterDetails`（`Name`/`Watts`/`AdapterVoltage`/`SerialString`） | mV→V |
| 风扇转速 | SMC `F{n}Ac`（`flt`） | RPM |
| 实时功耗 | SMC `PSTR` / `PDTR`，5 Hz | W |

`TimeRemaining` / `AvgTimeToEmpty` 在部分机型恒为 `65535`（无效值），因此续航由
`已存能量 Wh ÷ 当前功耗 W` 计算，不用系统字段。

---

## 构建

```bash
./build.sh                 # 产物：build/InfiniCal.app（arm64 + x86_64 通用）
open build/InfiniCal.app
```

需要 Xcode 16 或更新版本（或仅 Command Line Tools + Swift 6 工具链）。

用 Xcode：

```bash
open InfiniCal.xcodeproj   # Scheme: InfiniCal → ⌘R
```

| Target | 类型 | 产物 |
| --- | --- | --- |
| `InfiniCal` | macOS App | `InfiniCal.app` |
| `InfiniCalHelper` | Command Line Tool | `com.infinitycomputer.infinical.helper` |

工程文件由 `Tools/generate_xcodeproj.py` 生成，UUID 稳定。**新增或删除 `.swift` 后必须重跑**：

```bash
python3 Tools/generate_xcodeproj.py
```

调试参数：

```bash
build/InfiniCal.app/Contents/MacOS/InfiniCal --panel fanControl   # 直接打开某个面板
```

可用面板：`dashboard`、`chargeControl`、`calibration`、`fanControl`、`sleep`、`schedule`、`other`。

---

## 权限模型

写入 SMC 需要 **root**。App 本身只读，所有写入经一个特权守护进程：

- 安装：一次性管理员授权，落盘到 `/Library/PrivilegedHelperTools/com.infinitycomputer.infinical.helper`
- 通信：Unix socket `/var/run/com.infinitycomputer.infinical.helper.sock`，owner 为安装者，mode 0600
- 限制：只接受白名单命令（ping / info / read / write / socpower / exec），`exec` 只允许白名单可执行文件
- 首次启动时提示安装；未安装时风扇与校准的写入功能会明确提示需要助手

退出 App 时自动恢复：风扇模式写回 `F{n}Md = 0`，校准未完成则释放充电阻断。

---

## 目录结构

```
InfiniCal/
├── InfiniCal.xcodeproj/             Xcode 工程（Scheme: InfiniCal）
├── Tools/generate_xcodeproj.py      工程生成器
├── Sources/
│   ├── Core/
│   │   ├── SMC.swift                AppleSMC 用户客户端（80 字节负载）
│   │   ├── Battery.swift            电池 / 适配器 / PowerTelemetry 遥测
│   │   ├── ChargeController.swift   充电能力探测 + 特权助手客户端
│   │   ├── CalibrationModel.swift   校准采样点 / 记录 / 历史存储
│   │   ├── CalibrationMath.swift    库仑积分 / DCIR / 健康度融合
│   │   ├── CalibrationEngine.swift  校准状态机 + 硬件控制 + 报告导出
│   │   ├── FanController.swift      风扇读写 / 温度 / 曲线 / 预设
│   │   ├── PowerMeter.swift         实时功耗采样
│   │   ├── PowerEstimate.swift      无实测源时的标注估算
│   │   ├── PowerFormat.swift        瓦数格式化
│   │   ├── AppState.swift           状态机、控制循环、持久化
│   │   └── Models.swift / Theme.swift
│   ├── UI/                          仪表板 / 面板 / 功率流 / 图表 / 校准 / 风扇
│   └── main.swift
├── Helper/main.swift                root 守护进程
├── Resources/Info.plist, AppIcon.icns
├── Screenshots/
└── build.sh
```

---

## 系统要求

- macOS 12.0 Monterey 及以上，Intel 与 Apple Silicon 通用二进制
- 无风扇机型（如 MacBook Air）不显示风扇选项，只保留温度读数
- 支持写入风扇的机型：本机实测 MacBookPro19,1；Intel 机型走 `FS!` 回退路径

---

## 许可

Copyright © 2026 Infinity Computer. All rights reserved.

界面与交互参考了 AlDente Pro 的公开设计，代码与资源均为独立实现。未使用任何第三方库。