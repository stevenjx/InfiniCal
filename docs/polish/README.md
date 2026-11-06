# 界面美化各阶段的验收图

`UI_POLISH_PLAN.md` 每一项做完时的实机对比图，从 `dist/` 移到这里归档。
文件名前缀对应计划里的编号：`u003` = U0-03，`u109` = U1-09，`u202` = U2-02。

| 图 | 对应 | 说明 |
|---|---|---|
| `u003-before-after.png` | U0-03 | 卡片与标题收口 |
| `u004-before-after.png` | U0-04 | 页面骨架与空态 |
| `u101-before-after.png` | U1-01 | 侧边栏四档底色、强调条 |
| `u102-before-after.png` | U1-02 | 仪表板图表卡刻度与时间轴 |
| `u103-before-after.png` | U1-03 | 电池校准页常驻卡 14 → 6 |
| `u104-before-after.png` | U1-04 | 风扇控制页转速环 |
| `u105-before-after.png` | U1-05 | 历史页柱图与表格 |
| `u106-before-after.png` | U1-06 | 设置页分组 |
| `u107-before-after.png` | U1-07 | 定时设置页卡片高度 |
| `u108-before-after.png` | U1-08 | 充电控制页开关收进卡片 |
| `u109-before-after.png` | U1-09 | 六个弹窗统一 SheetScaffold |
| `u201-before-after.png` | U2-01 | 面板交叉淡入与图表描边 |
| `u202-before-after.png` | U2-02 | 空态 / 加载 / 错误三态 |

缺少 `u203`（无障碍）与 `u204`（浅色模式）：这两项没有做总结图，验收证据是
`Tools/screenshots/baseline/` 下的 16 张基线截图本身。

生成脚本不保留——每次都是针对当次改动临时写的。要看某一项怎么验的，
读 `UI_POLISH_PLAN.md` 对应条目的「实现说明」。
