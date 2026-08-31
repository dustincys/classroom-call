#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Copyright (c) 2026
# Author: YanshuoChu
# License: GPL-3.0

import json
import sys

import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

# -------------------- 中文字体设置 --------------------
plt.rcParams['font.sans-serif'] = [
    'SimHei', 'DejaVu Sans', 'Arial Unicode MS', 'WenQuanYi Micro Hei',
    'Noto Sans CJK'
]
plt.rcParams['axes.unicode_minus'] = False


def main(json_path, output_path):
    with open(json_path, 'r', encoding='utf-8') as f:
        d = json.load(f)

    labels = d['labels']  # 等级名称（0~4）
    classes = d['classes']  # 班级名称
    data = d['data']  # 二维列表，每行是一个班级的五个等级计数
    # 等级索引 -> 分数（由 Elisp 传入，与评分提示保持一致）
    score_map = d.get('scores', [0, 60, 80, 98, 100])

    n_groups = len(classes)
    n_bars = len(labels)

    # X 轴坐标（每个班级一组）
    x = np.arange(n_groups)
    width = 0.8 / n_bars

    fig, ax1 = plt.subplots(figsize=(max(8, n_groups * 1.2), 5))

    # ---------- 绘制垂直分组柱状图 ----------
    for i in range(n_bars):
        values = [row[i] for row in data]
        ax1.bar(x + i * width, values, width, label=labels[i])

    # 设置 X 轴刻度标签为班级名
    ax1.set_xticks(x + width * (n_bars - 1) / 2)
    # 若班级名称较长，自动旋转标签，避免文字重叠
    max_label_len = max((len(str(c)) for c in classes), default=0)
    if max_label_len > 8:
        rotation, ha = 90, 'center'
    elif max_label_len > 4:
        rotation, ha = 45, 'right'
    else:
        rotation, ha = 0, 'center'
    ax1.set_xticklabels(classes, rotation=rotation, ha=ha)
    ax1.set_ylabel('次数')

    # ---------- 分数映射（来自 JSON） ----------

    # 计算每个班级的平均分
    avg_scores = []
    for row in data:
        total = sum(row)
        if total > 0:
            avg = sum(score_map[i] * row[i] for i in range(5)) / total
        else:
            avg = 0.0
        avg_scores.append(avg)

    # 计算全体学生的总平均分
    total_counts = [sum(col) for col in zip(*data)]  # 各等级的总人数
    total_answers = sum(total_counts)
    if total_answers > 0:
        overall_avg = sum(score_map[i] * total_counts[i]
                          for i in range(5)) / total_answers
    else:
        overall_avg = 0.0

    # 创建第二个 Y 轴（右侧），用于显示平均分（0-100）
    ax2 = ax1.twinx()
    centers = x + width * (n_bars - 1) / 2
    ax2.plot(centers,
             avg_scores,
             color='red',
             marker='o',
             linewidth=2,
             markersize=6,
             label='班级平均成绩')

    # ---------- 为每个班级标注具体平均分 ----------
    for xi, avg in zip(centers, avg_scores):
        ax2.text(xi,
                 avg + 2,
                 f'{avg:.1f}',
                 ha='center',
                 va='bottom',
                 fontsize=8,
                 color='red',
                 fontweight='bold')

    # 添加全员平均成绩水平线
    ax2.axhline(y=overall_avg,
                color='red',
                linestyle='--',
                linewidth=1.5,
                label=f'全员平均成绩 ({overall_avg:.1f})')

    ax2.set_ylabel('成绩 (分数)', color='red')
    ax2.tick_params(axis='y', labelcolor='red')
    ax2.set_ylim(0, 100)
    # 合并两个轴的图例，放在图下方（X 轴标签之下），避免遮挡
    handles, labels = [], []
    for a in (ax1, ax2):
        h, l = a.get_legend_handles_labels()
        handles += h
        labels += l
    fig.legend(handles, labels,
               loc='lower center', bbox_to_anchor=(0.5, 0.0),
               ncol=len(handles), borderaxespad=0)

    ax1.set_title('各班成绩分布与平均成绩')
    # 下方预留空间给图例，保证旋转后的 X 轴标签不被图例遮挡
    plt.tight_layout(rect=[0, 0.12, 1, 1])
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    print(f"Chart saved to {output_path}")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python3 classroom_plot.py <json_path> <output_png>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
