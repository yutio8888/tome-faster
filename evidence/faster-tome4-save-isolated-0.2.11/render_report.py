#!/usr/bin/env python3
"""Render tables only from the complete validated isolated experiment summary."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent
LABELS = {
    'base62-save': 'base62 保存',
    'inventory-idle': '库存：无新事件',
    'inventory-add': '库存：添加 24 件后保存',
    'fearscape-idle': 'Fearscape：无新事件',
    'fearscape-exit': 'Fearscape：施法者死亡退出后保存',
}
EVENTS = {
    'inventory-add': [('inventory_add', '24 次物品添加')],
    'fearscape-exit': [('entry_sync', '进入：同步调用'), ('entry_observed', '进入：确认完成'),
                       ('exit_sync', '退出：同步死亡调用'), ('exit_observed', '退出：确认完成')],
}


def number(value):
    return f'{value:,.1f}'.removesuffix('.0')


def main():
    result = json.loads((ROOT / 'isolated-results.json').read_text())
    assert result['validated_sessions'] == 300 and result['validated_pairs'] == 150
    cases = result['cases']
    lines = [
        '# 存档优化的单项影响：0.2.11 独立开关测试', '',
        '2026-09-14。五个场景各完成 30 对、60 次保存，合计 300 次。'
        '每对使用同一个冻结包，仅改变一个新开关；下表只使用本轮数据。', '',
        '三项新选项继续默认关闭。本次补充单项测量，没有修改生产代码或重打包。', '',
        '## 保存 CPU 与文件大小', '',
        '主档为 `yron/game.teag`。CPU 列为完整保存的全进程 user CPU；'
        'A/B 列取各自均值，百分比与上界使用配对对数比。字节减少取两个中位数之差。', '',
        '| 单独启用的场景 | 主档减少 | 保存 user CPU：A → B | 配对变化 | 单侧 95% 上界 | 保存 <1% 门槛 |',
        '| --- | ---: | ---: | ---: | ---: | --- |',
    ]
    for case, label in LABELS.items():
        row = cases[case]
        metric = row['metrics']['save_process_user_ms']
        size = row['archives']['by_archive']['yron/game.teag']['metrics']['bytes']
        a, b = (size[v]['median_bytes'] for v in ('baseline', 'candidate'))
        reduction = a - b
        lines.append(f"| {label} | {number(reduction)} B（{100*reduction/a:.4f}%） | "
                     f"{metric['baseline']['mean_ms']:.3f} → {metric['candidate']['mean_ms']:.3f} ms | "
                     f"{metric['paired_geomean_change_pct']:+.3f}% | {metric['one_sided_95pct_upper_change_pct']:+.3f}% | "
                     f"{'本场景通过' if row['save_cpu_decision']=='pass' else '未证明'} |")
    lines.extend(['',
        '“未证明”表示这 30 对的置信上界没有低于 +1%，不等于已经证明开销大于 1%。'
        '保存通过也不覆盖事件自身或整个游戏生命周期。', '',
        '| 场景 | 主档字节 A → B | 未压缩字节 A → B | 条目数 A → B | 全部归档中位数 A → B |',
        '| --- | ---: | ---: | ---: | ---: |',
    ])
    for case, label in LABELS.items():
        row = cases[case]
        archive = row['archives']['by_archive']['yron/game.teag']['metrics']
        total = row['archives']['totals']['all_archives']['bytes']
        values = []
        for field, unit in (('bytes','bytes'), ('raw_bytes','bytes'), ('entries','count')):
            values.append(' → '.join(number(archive[field][v]['median_'+unit]) for v in ('baseline','candidate')))
        values.append(' → '.join(number(total[v]['median_bytes']) for v in ('baseline','candidate')))
        lines.append('| '+label+' | '+' | '.join(values)+' |')
    lines.extend(['', '## 事件自身的成本', '',
        '以下每行仍为 30 对事件，采用 B−A 的配对绝对差；单位均为 ms。'
        '同步调用与确认完成区间相互包含，不能相加。进入阶段是对照，清理发生在退出时。', '',
        '| 事件阶段 | 全进程 user CPU：A → B | 差值 B−A | 两侧 95% 差值区间 | A/B 零读数（各 30 次） |',
        '| --- | ---: | ---: | ---: | ---: |',
    ])
    for case, phases in EVENTS.items():
        for prefix, label in phases:
            m = cases[case]['metrics'][prefix+'_process_user_ms']
            lo, hi = m['two_sided_95pct_delta_ci_ms']
            lines.append(f"| {label} | {m['baseline']['mean_ms']:.4f} → {m['candidate']['mean_ms']:.4f} | "
                         f"{m['paired_mean_delta_ms']:+.4f} | [{lo:+.4f}, {hi:+.4f}] | "
                         f"{m['baseline']['zero_count']} / {m['candidate']['zero_count']} |")
    lines.extend(['',
        '| 同一事件阶段 | 主线程总 CPU：A → B | 差值及两侧 95% 区间 | 墙钟：A → B |',
        '| --- | ---: | ---: | ---: |',
    ])
    for case, phases in EVENTS.items():
        for prefix, label in phases:
            m = cases[case]['metrics'][prefix+'_thread_cpu_ms']
            wall = cases[case]['metrics'][prefix+'_wall_ms']
            lo, hi = m['two_sided_95pct_delta_ci_ms']
            lines.append(f"| {label} | {m['baseline']['mean_ms']:.4f} → {m['candidate']['mean_ms']:.4f} | "
                         f"{m['paired_mean_delta_ms']:+.4f} [{lo:+.4f}, {hi:+.4f}] | "
                         f"{wall['baseline']['mean_ms']:.4f} → {wall['candidate']['mean_ms']:.4f} |")
    lines.extend(['',
        '主线程总 CPU 含 user 和 system，仅为很短事件的补充观察，不能改称 user CPU。'
        '数值精度显示的是样本均值，并非严格计量误差保证。', '',
        '| 两个不重叠区间之和 | 全进程 user CPU：A → B | 差值及两侧 95% 区间 |',
        '| --- | ---: | ---: |',
    ])
    for case, label in (('inventory-add', '24 次添加 + 完整保存'), ('fearscape-exit', '确认退出 + 完整保存')):
        m = cases[case]['metrics']['event_and_save_process_user_ms']
        lo, hi = m['two_sided_95pct_delta_ci_ms']
        lines.append(f"| {label} | {m['baseline']['mean_ms']:.3f} → {m['candidate']['mean_ms']:.3f} ms | "
                     f"{m['paired_mean_delta_ms']:+.3f} [{lo:+.3f}, {hi:+.3f}] ms |")
    lines.extend(['', '## 计量方法与范围', '', (ROOT/'report-methods.md').read_text().strip(), '',
                  '## 完整性、兼容性与结论', '',
                  '<!-- Add final compatibility, interpretation, evidence links only after all checks finish. -->', ''])
    (ROOT/'isolated-report-draft.md').write_text('\n'.join(lines))


if __name__ == '__main__':
    main()
