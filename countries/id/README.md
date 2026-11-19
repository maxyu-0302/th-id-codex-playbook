# 印尼｜离线复算经营日报

[印尼知识库](../../03-印尼/README.md) · [六个历史对话](../../04-对话索引/README.md)

**接日报**先跑一次下方离线例子，再读[每日运行与异常处理](operations.md)。**接月切或目标**先选要复现的月份，读[项目地图](projects.md)与[规则变更记录](decisions.md)。**查旧版**按交付物原名在[历史目录](inventory.md)定位。本文档基线为 2026-11-19，最近一次验证使用 11 月 18 日业务数据。

| 要解决的问题 | 从哪里开始 | 应交付什么 |
|---|---|---|
| 今天是否落后，具体在哪个账龄／队列 | [运行手册](operations.md)、[目标和人员](targets.md) | 已对账的 HTML、人民币群消息预览 |
| 财务侧多了或少了多少钱 | [实收对账](receipts.md) | 从原报表到财务合计的逐项金额桥接 |
| 下个月会进多少案，部署后是否按计划分 | [预测](knowledge/forecast.md)、[独立核验](knowledge/forecast-validation.md) | 按日分案、在手、人力及与目标制定版的差异 |
| 哪个客群值得切换作业方式 | [同池对比](knowledge/strategy-comparison.md)、[专题](projects.md) | 同池实收、成本、净实收变化及样本覆盖 |
| 已发现的新问题应不应该改规则 | [决策记录](decisions.md)、[复盘模板](../../common/decision-review.md) | 有适用范围、复核方式及结果的变更记录 |

从仓库根目录运行以下命令。只需 Python 3，无需联网或接数仓。示例只含账龄和模式汇总。把文件参数换成授权环境的每日归档数据快照，也可复算同一组指标。

```sh
python countries/id/tools/replay.py countries/id/examples/2026-11-18.json
```

应得到整体实收 794,939.15 元、序时达成 102.1%，常规人催 44.74 万元、103.7%，冻结＋Other 9.96 万元、120.0%。这一步验证汇总和群消息口径。流水唯一性和财务差额另有 SQL 与核验步骤。

Codex 可从[印尼长账分析技能](../../.agents/skills/id-long-collections/SKILL.md)进入，或直接让它“读 countries/id/README.md，用指定截止日快照复算日报，解释最大的两个缺口，附上口径和未决项”。继续维护请对照[指标定义](metrics.md)、[通用比较方法](../../common/analysis.md)与[维护约定](../../common/maintenance.md)。
