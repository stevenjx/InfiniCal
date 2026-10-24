# InfiniCal

[English](README.en.md) · 简体中文

macOS 电池工具，由 Infinity Computer 开发：**测量真实电池健康**，并控制充电与散热。

macOS 显示的「最大容量」是电量计固件的历史估算。InfiniCal 跑一次受控完整循环（满充 → 深度放电 → 复充 → 静置 → 回落），
对电流做梯形积分，算出这一轮真正搬运了多少电荷，从而得到真实满容量、健康度、库仑效率与直流内阻。
散热与充电直接读写 SMC。所有数据来自本机 IORegistry、SMC 与 IOHID，**没有估算、没有编造**：读不到就显示 `--` 并说明原因。

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

- **库仑计数** — 梯形积分 `∫I dt`，25 mA 零点死区，跨度 > 5 s 的采样段整段丢弃（休眠/卡顿不累加）
- **真实容量** — `放电电量 ÷ (起始电量 − 终止电量)`，输出 Wh 与 mAh
- **库仑效率** — `放电 Ah ÷ 复充 Ah`
- **DCIR** — 电流阶跃 ≥ 1 A 且电压反向响应，中位数后 EWMA，约束 10–600 mΩ
- **健康度** — 本轮实测 65% + 固件先验 35%，多轮记录按 `exp(-0.35·n)` 衰减加权
- **电芯一致性** — 逐串电压与压差 ΔV

结束后导出 TXT 报告与 CSV 全量遥测到 `~/Library/Application Support/InfiniCal/Reports/`。

### 风扇控制

自动发现风扇数量（`FNum`），Apple Silicon 与 Intel 通吃。

| 模式 | 行为 |
| --- | --- |
| 自动 | 清除强制位，交回 SMC 的固件策略 |
| 自定义 | 滑块设定固定转速（步进 50 RPM） |
| 全速 | 目标转速 = `F{n}Mx` |
| 温度曲线 | 起始 / 中点 / 满载三个锚点分段线性；温度变化 < 1 °C 不重写，转速每秒最多变化 150 RPM |

温度来源标注在界面上：CPU（IOHID `PMU tdie*`，回退 SMC `Tp01/Tp05/Tp09/Tp0D`）、电池（`TB0T`）、
固态硬盘（`NAND`）、GPU（`Tg0B/Tg0C/Tg0H/TG0V`，仅当键存在）。

### 充电控制

充电限制、允许低于 80%、自动放电、航海模式、过热保护。按机型选择可用的控制键：
Apple Silicon 用 `BCLM`（上限）或 `CHIE`（禁止），Intel/T2 用 `CH0B`/`CH0C`，运行时探测。

- **充满**是一次性放行：限制临时抬到 100%，充满并拔下电源后（或 4 小时后）自动恢复原值。
- **按时间充满**：其余时间维持上限，按「缺口电量 ÷ 实测充电功率」反推开始时间。
- **适配器诊断**：额定 / 输入 / 系统 / 电池 / 余量 / 转换损耗；适配器带不动时明确提示电池在放电。

### 菜单栏与通知

App 以 `.accessory` 运行，菜单栏是关闭窗口后回到界面的入口：电量、状态、温度、风扇、适配器，以及
充满 / 暂停 / 设为 80% / 风扇自动等快捷操作。

通知覆盖：达到充电上限、充满、过热保护触发与恢复、一次性充满完成。每个事件带冷却，不会每 2 秒弹一次。

### 历史

按自然日聚合充入 / 放出电量、温度区间、接电时长与健康度，保留 400 天，「历史」页可看 7 / 30 天趋势。
校准记录页顶部另有健康度、实测容量、直流内阻的跨次趋势。

### 睡眠与能源

- 睡眠前按设置写入充电禁止位，唤醒后重新评估。
- 「完全禁用睡眠」用 `IOPMAssertion` 阻止空闲睡眠，可同时决定是否让显示器睡眠。
- 合盖锁屏轮询 `IOPMrootDomain.AppleClamshellState`。
- 「后台仪表板更新」关闭时，窗口不在前台就停止 0.5 s 功耗采样与图表记录。

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
| 适配器 | `AdapterDetails` | mV→V |
| 风扇转速 | SMC `F{n}Ac`（`flt`） | RPM |
| 实时功耗 | SMC `PSTR` / `PDTR`，5 Hz | W |

`TimeRemaining` 在部分机型恒为 `65535`，因此续航由 `已存能量 Wh ÷ 当前功耗 W` 计算。

---

## 构建

```bash
./build.sh                 # 产物：build/InfiniCal.app（arm64 + x86_64 通用）
open build/InfiniCal.app
```

需要 Xcode 16 或更新版本（或仅 Command Line Tools + Swift 6 工具链）。也可以直接 `open InfiniCal.xcodeproj`。

工程文件由 `Tools/generate_xcodeproj.py` 生成，**新增或删除 `.swift` 后必须重跑**。

调试参数：

```bash
build/InfiniCal.app/Contents/MacOS/InfiniCal --panel fanControl   # 直接打开某个面板
build/InfiniCal.app/Contents/MacOS/InfiniCal --menubar            # 直接展开菜单栏弹窗
```

可用面板：`dashboard`、`chargeControl`、`calibration`、`fanControl`、`sleep`、`history`、`schedule`、`other`。

---

## 本地化

界面随系统语言在简体中文与英文之间切换。源码以中文为源语言，英文词条在 `Resources/en.json`，
缺失时回退到中文；插值文案用 `{p}` 占位符，允许译文调整语序。

---

## 权限模型

写入 SMC 需要 **root**。App 本身只读，所有写入经一个特权守护进程：

- 安装：一次性管理员授权，落盘到 `/Library/PrivilegedHelperTools/com.infinitycomputer.infinical.helper`
- 通信：Unix socket `/var/run/com.infinitycomputer.infinical.helper.sock`，owner 为安装者，mode 0600
- 限制：只接受白名单命令（ping / info / read / write / socpower / exec），`exec` 只允许白名单可执行文件

退出 App 时自动恢复：风扇模式写回 `F{n}Md = 0`，校准未完成则释放充电阻断。

彻底移除助手（App 内不提供卸载入口）：

```bash
sudo launchctl bootout system/com.infinitycomputer.infinical.helper
sudo rm -f /Library/PrivilegedHelperTools/com.infinitycomputer.infinical.helper \
           /Library/LaunchDaemons/com.infinitycomputer.infinical.helper.plist \
           /var/run/com.infinitycomputer.infinical.helper.sock
```

---

## 目录结构

```
InfiniCal/
├── InfiniCal.xcodeproj/             Xcode 工程
├── Tools/generate_xcodeproj.py      工程生成器
├── Sources/
│   ├── Core/
│   │   ├── SMC.swift                AppleSMC 用户客户端（80 字节负载）
│   │   ├── L10n.swift               运行时本地化（中文源 + en.json）
│   │   ├── Battery.swift            电池 / 适配器 / PowerTelemetry 遥测
│   │   ├── ChargeController.swift   充电能力探测 + 特权助手客户端
│   │   ├── Calibration*.swift       校准采样 / 数学 / 状态机
│   │   ├── HistoryStore.swift       按天聚合的长期历史
│   │   ├── Notifier.swift           事件通知（按事件冷却去重）
│   │   ├── SleepControl.swift       电源断言 / 合盖状态 / 锁屏
│   │   ├── FanController.swift      风扇读写 / 温度 / 曲线 / 预设
│   │   ├── Power*.swift             实时功耗采样与格式化
│   │   └── AppState.swift           状态机、控制循环、持久化
│   ├── UI/                          仪表板 / 面板 / 功率流 / 图表 / 校准 / 风扇 / 历史 / 菜单栏
│   └── main.swift
├── Helper/main.swift                root 守护进程
├── Resources/                       Info.plist、图标、en.json
└── build.sh
```

---

## 系统要求

- macOS 12.0 Monterey 及以上，Intel 与 Apple Silicon 通用二进制
- 无风扇机型不显示风扇选项，只保留温度读数
- 支持写入风扇的机型：本机实测 MacBookPro19,1；Intel 机型走 `FS!` 回退路径

---

## 许可

Copyright © 2026 Infinity Computer. All rights reserved.

界面与交互参考了 AlDente Pro 的公开设计，代码与资源均为独立实现。未使用任何第三方库。
