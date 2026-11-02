<div align="center">

# InfiniCal

**macOS 电池健康与充电控制工具**

[English](README.en.md) · 简体中文

[![macOS 12+](https://img.shields.io/badge/macOS-12%2B-111827?logo=apple&logoColor=white)](https://github.com/stevenjx/InfiniCal/releases) [![Universal](https://img.shields.io/badge/arm64%20%2B%20x86__64-universal-2563eb)](https://github.com/stevenjx/InfiniCal/releases) [![Latest Release](https://img.shields.io/github/v/release/stevenjx/InfiniCal?label=release&color=16a34a)](https://github.com/stevenjx/InfiniCal/releases)

<p>
  <img src="Screenshots/Dashboard_CH.png" alt="InfiniCal 中文界面" width="900">
</p>

</div>

## 一句话介绍

InfiniCal 从本机 IORegistry、SMC 和 IOHID 读取数据，用于**测量真实电池健康**，并控制充电、放电与散热。读不到的数据显示为 `--`，不伪造估算值。

## 功能

| 模块 | 能力 |
| --- | --- |
| 电池校准 | 满充、受控放电、复充、静置与回落；输出真实容量、健康度、库仑效率和 DCIR |
| 充电控制 | 充电上限、低于 80% 的限制、自动放电、航海模式、过热保护 |
| 风扇控制 | 自动、自定义、全速和温度曲线 |
| 实时监控 | 电量、电流、电压、功耗、温度、适配器和风扇 |
| 历史与报告 | 校准记录、TXT 报告和 CSV 遥测数据 |
| 本地化 | 跟随系统、中文或英文界面 |

## 下载

前往 [Releases](https://github.com/stevenjx/InfiniCal/releases) 下载最新版本。

**当前版本：1.0.12** · arm64 + x86_64 通用包 · macOS 12 Monterey 及以上

> 应用使用 ad-hoc 签名，未经 Apple 公证。首次打开可能需要在系统设置中允许运行。

## 构建

```bash
./build.sh
open build/InfiniCal.app
```

需要 Xcode 16 或更新版本，或包含 Swift 6 工具链的 Command Line Tools。

## 权限与兼容性

读取数据不需要特权。写入 SMC、控制充电和风扇需要安装特权助手，应用会在需要时请求管理员授权。

Apple Silicon 与 Intel/T2 使用不同的硬件控制路径，具体能力取决于机型、固件和 macOS 版本。

## 许可

Copyright © 2026 Infinity Computer. All rights reserved.

界面与交互参考了 AlDente Pro 的公开设计，代码与资源均为独立实现。
