<img src="https://raw.githubusercontent.com/dustincys/cn/refs/heads/assets/classroom-call-logo.png" alt="logo" width="150" >

# classroom-call — 课堂随机提问系统

一个 Emacs 扩展，用于在课堂上随机点名提问，支持语音播报、评分记录、统计图表和 CSV 导出。

---

## 目录

- [功能特性](#功能特性)
- [依赖](#依赖)
- [安装](#安装)
- [快速开始](#快速开始)
- [学生名单格式](#学生名单格式)
- [用法](#用法)
  - [启动系统](#启动系统)
  - [点名流程](#点名流程)
  - [评分标准](#评分标准)
  - [键盘快捷键](#键盘快捷键)
  - [统计与图表](#统计与图表)
  - [导出 CSV](#导出-csv)
- [TTS 语音播报](#tts-语音播报)
- [持久化与状态恢复](#持久化与状态恢复)
- [无回答处理机制](#无回答处理机制)
- [自定义配置](#自定义配置)
- [文件说明](#文件说明)
- [许可证](#许可证)

---

## 功能特性

- **随机点名** — 从学生池中随机抽取学生，配合滚动动画，增强课堂互动性
- **TTS 语音播报** — 使用 Edge-TTS 将学生姓名和评分结果朗读出来，支持缓存
- **五级评分制** — 内置 0–4 分评分标准，兼顾回答正确性与逻辑表达能力
- **多轮次支持** — 支持多轮点名，每轮学生顺序随机打乱
- **Org 记录** — 全部点名和评分记录以 Org mode 格式保存，方便检索和回顾
- **无回答处理** — 累计无回答 ≤2 次的学生推迟到下一节，第 3 次则移出本轮点名池
- **取消提问** — 允许取消当前点名，被点学生放回池中重新随机
- **状态持久化** — 课堂状态（当前轮次、剩余池、历史记录等）自动保存，Emacs 重启后可恢复
- **统计图表** — 按班级生成成绩分布柱状图（含平均分折线），直观展示各班级表现
- **CSV 导出** — 将全部成绩导出为 CSV，每轮一列，便于在电子表格中分析
- **Pure Emacs Lisp** — 除外部工具调用外，核心逻辑纯 Elisp 实现

---

## 依赖

| 组件 | 用途 | 安装方式 |
|------|------|----------|
| **Emacs** ≥ 27 | 运行平台 | 系统包管理器 |
| **Python 3** | 拼音转换、图表生成 | `apt install python3` / `brew install python3` |
| **pypinyin** | 中文姓名转拼音 | `pip3 install pypinyin` |
| **matplotlib + numpy** | 生成成绩分布图表 | `pip3 install matplotlib numpy` |
| **edge-tts** | TTS 语音合成 | `pip3 install edge-tts` |
| **mpv** 或 **ffplay** | 播放合成语音 | `apt install mpv` / `brew install mpv` |

> 如果不使用 TTS 功能，可跳过 `edge-tts` 和 `mpv` 的安装，并将 `classroom-enable-tts` 设为 `nil`。

---

## 安装

将 `classroom-call.el` 所在目录添加到 `load-path`，然后在 Emacs 配置中加载：

```elisp
(add-to-list 'load-path "/path/to/classroom-call/")
(require 'classroom-call)
```

建议使用 `use-package`：

```elisp
(use-package classroom-call
  :load-path "/path/to/classroom-call/"
  :custom
  (classroom-enable-tts t)
  (classroom-tts-voice "zh-CN-XiaoxiaoNeural")
  (classroom-tts-player-command '("mpv" "--volume-max=200")))
```

---

## 快速开始

1. 准备一份学生名单 CSV 文件（格式见[学生名单格式](#学生名单格式)）
2. 在 Emacs 中执行 `M-x classroom-start`
3. 选择学生名单 CSV 文件（首次启动）
4. 按 `c` 开始点名
5. 学生回答后按数字键 `0`–`4` 评分，或按 `c` 取消本次提问
6. 重复直到所有学生回答完毕

---

## 学生名单格式

CSV 文件包含三列：学号、姓名、班级。第一行为表头。

```csv
id,name,group
20230001,张三,1班
20230002,李四,2班
20230003,王五,2班
20230004,赵六,3班
20230005,孙七,3班
```

- **id**：学号，作为唯一标识
- **name**：姓名（支持中文，自动生成拼音）
- **group**：班级/分组

默认从 `classroom-default-students-file`（`user-emacs-directory` 下的 `students.csv`，避免写入包目录）加载，也可在互动提示中手动选择其他文件。

---

## 用法

### 启动系统

| 命令 | 说明 |
|------|------|
| `M-x classroom-start` | 启动课堂系统。如检测到上次状态文件，会询问是否恢复 |
| `M-x classroom-load-csv` | 手动重新加载学生名单 CSV |
| `M-x classroom-load-state` | 手动恢复上次保存的课堂状态 |

### 点名流程

1. 按下 `c`（`classroom-call`）触发点名
2. 屏幕上出现滚动动画（随机快速切换学生姓名）
3. 动画结束后，最终被点中的学生信息全屏显示
4. 如启用了 TTS，系统会用中文朗读"请 XXX 回答问题"
5. 等待教师输入评分（0–4）或取消（c）

### 评分标准

| 按键 | 等级 | 描述 |
|------|------|------|
| `0` | 无回答 | 学生未回答问题 |
| `1` | 回答错误且无解释或解释无逻辑 | 答案和解释均有问题 |
| `2` | 回答正确，但无解释或解释无逻辑 | 答案正确但说不清原因 |
| `3` | 回答正确解释有逻辑，或回答错误但解释很有逻辑 | 逻辑清晰，无论对错都值得肯定 |
| `4` | 推翻已有结论并提出新观点 | 批判性思维，超越标准答案 |
| `c` | 取消 | 取消本次提问，学生放回池中 |

### 键盘快捷键

在 `*Classroom Call*` 缓冲区中，以下快捷键可用（由 `classroom-mode` 提供）：

| 按键 | 命令 | 说明 |
|------|------|------|
| `c` | `classroom-call` | 开始点名 |
| `s` | `classroom-show-statistics` | 显示统计信息和成绩分布图 |
| `p` | `classroom-show-pool` | 显示当前轮次剩余学生列表 |
| `t` | `classroom-precache-tts` | 预生成全部 TTS 语音缓存 |
| `T` | `classroom-preheat-tts` | 后台预热 TTS 缓存（空闲时自动执行） |
| `C` | `classroom-clear-tts-cache` | 清空 TTS 缓存目录 |

### 统计与图表

按 `s` 或执行 `M-x classroom-show-statistics` 可查看：

- 当前轮次和剩余/已回答人数
- 按班级分组的成绩分布柱状图（0–4 等级计数）
- 各班级平均分折线（映射：0→0, 1→60, 2→80, 3→98, 4→100）
- 全员平均分参考线
- 当前挂起（无回答推迟）的学生列表

图表由 Python（matplotlib）生成并保存为 PNG 图片，嵌入 Org 缓冲区显示。

### 导出 CSV

执行 `M-x classroom-export-csv` 将全部点名记录导出为 CSV：

```csv
姓名,学号,班级,Round1,Round2,Round3
张三,20230001,1班,3,0,1
李四,20230002,2班,1,0,1
...
```

每轮的成绩以数字（0–4）表示，未参与轮次留空。适用于 Excel / Google Sheets 进一步分析。

---

## TTS 语音播报

系统使用 Microsoft Edge TTS 引擎合成语音：

- **学生点名**："请 XXX 回答问题"
- **评分播报**：朗读评分等级文字（如"回答正确解释有逻辑"）

### 缓存机制

合成后的语音文件以 MD5 哈希命名缓存在 `classroom-tts-cache-dir` 目录中。同一文本不重复合成。

### 预热

建议在课堂开始前执行 `t`（`classroom-precache-tts`）预先生成所有语音文件，避免点名时等待。`classroom-start` 启动后也会自动在后台预热。

### 自定义 TTS

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `classroom-enable-tts` | `t` | 是否启用语音播报 |
| `classroom-tts-voice` | `"zh-CN-XiaoxiaoNeural"` | Edge-TTS 语音角色 |
| `classroom-tts-rate` | `"+50%"` | 语速（`"+0%"` 为正常） |
| `classroom-tts-player-command` | `'("mpv" "--volume-max=200")` | 音频播放器命令 |

---

## 持久化与状态恢复

课堂状态自动保存在 `classroom-state.el` 中，包括：

- 当前轮次编号
- 当前点名池（剩余学生及顺序）
- 全部历史评分记录
- 学生名单
- 最后取消的学生 ID
- 无回答累计计数
- 挂起（推迟）学生列表

每次评分后自动保存。下次启动时，系统会询问是否恢复上次状态。

---

## 无回答处理机制

当学生对点名无回答（评分为 0）时：

1. **第 1–2 次无回答**：学生被放入 `classroom-unanswered-pool`，推迟到下次启动时重新加入点名池
2. **第 3 次无回答**：学生永久移出当前轮次的点名池
3. 如果学生之后正常回答了问题（1–4 分），其无回答计数和挂起状态会被清除

此机制确保无回答的学生有机会在后续课堂中被再次点到，但不会无限期逃避。

---

## 自定义配置

所有可配置项均可通过 `M-x customize-group RET classroom-call RET` 进行可视化调整，或在配置文件中手动设置：

```elisp
;; 文件路径
(setq classroom-directory "/path/to/classroom-call/")
(setq classroom-org-file "/path/to/classroom-record.org")
(setq classroom-state-file "/path/to/classroom-state.el")
(setq classroom-default-students-file "/path/to/students.csv")
(setq classroom-stats-image-file "/path/to/stats.png")
(setq classroom-export-csv-default-file "/path/to/grades.csv")

;; TTS 设置
(setq classroom-enable-tts nil)              ; 禁用语音
(setq classroom-tts-voice "zh-CN-YunxiNeural")
(setq classroom-tts-rate "+30%")
(setq classroom-tts-player-command '("ffplay" "-nodisp" "-autoexit" "-loglevel" "quiet"))

;; 点名动画 / TTS 并发 / CSV
(setq classroom-roll-duration 2.5)           ; 点名动画时长（秒），C-u c 可跳过
(setq classroom-tts-max-concurrent 2)        ; TTS 并发生成进程数
(setq classroom-csv-skip-header t)           ; 学生名单 CSV 是否含表头
(setq classroom-export-csv-add-bom nil)      ; 导出 CSV 是否添加 UTF-8 BOM（Excel 中文环境建议开启）
```

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `classroom-call.el` | 核心源码（点名、评分、TTS、统计、导出） |
| `classroom-plot.py` | Python 图表生成脚本（matplotlib） |
| `classroom-record.org` | 点名记录文件（自动生成，Org 格式） |
| `classroom-state.el` | 持久化状态文件（自动生成） |
| `classroom-grades.csv` | 导出的成绩 CSV（默认文件名） |
| `classroom-stats.png` | 统计图表（自动生成） |
| `classroom-tts-cache/` | TTS 语音缓存目录（自动生成） |
| `students.csv` | 示例学生名单 |

---

## 许可证

GPL-3.0

---

# classroom-call — Random Student Call System for Classroom

An Emacs extension for randomly calling on students in class, with TTS voice announcements, grading, statistics charts, and CSV export.

---

## Table of Contents

- [Features](#features)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Student List Format](#student-list-format)
- [Usage](#usage)
  - [Starting the System](#starting-the-system)
  - [Call Flow](#call-flow)
  - [Grading Rubric](#grading-rubric)
  - [Keyboard Shortcuts](#keyboard-shortcuts)
  - [Statistics & Charts](#statistics--charts)
  - [CSV Export](#csv-export)
- [TTS Voice Announcements](#tts-voice-announcements)
- [Persistence & State Recovery](#persistence--state-recovery)
- [No-Answer Handling](#no-answer-handling)
- [Customization](#customization)
- [File Overview](#file-overview)
- [License](#license)

---

## Features

- **Random Student Selection** — Randomly picks students from a pool with a rolling animation for classroom engagement
- **TTS Voice Announcements** — Uses Microsoft Edge TTS to speak student names and grades aloud, with caching
- **Five-Level Grading** — Built-in 0–4 grading rubric covering both answer correctness and logical reasoning
- **Multi-Round Support** — Supports multiple rounds of questioning with reshuffled order each round
- **Org Mode Records** — All call and grading records saved in Org mode format for easy review and retrieval
- **No-Answer Handling** — Students with ≤2 no-answers are postponed to the next session; 3rd no-answer removes them from the pool
- **Cancel & Reshuffle** — Cancel a call and return the student to the pool for re-randomization
- **State Persistence** — Classroom state (round, pool, history) auto-saves and survives Emacs restarts
- **Statistics Charts** — Per-class grade distribution bar charts with average score line, generated via Python/matplotlib
- **CSV Export** — Export all grades as CSV with per-round columns for spreadsheet analysis
- **Pure Emacs Lisp** — Core logic implemented entirely in Elisp, with external tools for auxiliary tasks

---

## Dependencies

| Component | Purpose | Installation |
|-----------|---------|--------------|
| **Emacs** ≥ 27 | Runtime platform | System package manager |
| **Python 3** | Pinyin conversion, chart generation | `apt install python3` / `brew install python3` |
| **pypinyin** | Chinese name → pinyin | `pip3 install pypinyin` |
| **matplotlib + numpy** | Grade distribution charts | `pip3 install matplotlib numpy` |
| **edge-tts** | TTS voice synthesis | `pip3 install edge-tts` |
| **mpv** or **ffplay** | Audio playback | `apt install mpv` / `brew install mpv` |

> If TTS is not needed, skip `edge-tts` and `mpv` installation and set `classroom-enable-tts` to `nil`.

---

## Installation

Add the directory containing `classroom-call.el` to your `load-path`, then load it in your Emacs config:

```elisp
(add-to-list 'load-path "/path/to/classroom-call/")
(require 'classroom-call)
```

Recommended: use `use-package`:

```elisp
(use-package classroom-call
  :load-path "/path/to/classroom-call/"
  :custom
  (classroom-enable-tts t)
  (classroom-tts-voice "zh-CN-XiaoxiaoNeural")
  (classroom-tts-player-command '("mpv" "--volume-max=200")))
```

---

## Quick Start

1. Prepare a student roster CSV file (see [Student List Format](#student-list-format))
2. In Emacs, run `M-x classroom-start`
3. Select the student CSV file (first-time launch only)
4. Press `c` to start a call
5. After the student answers, press `0`–`4` to grade, or `c` to cancel
6. Repeat until all students have been called

---

## Student List Format

The CSV file contains three columns: Student ID, Name, and Group. The first row is the header.

```csv
id,name,group
20230001,张三,1班
20230002,李四,2班
20230003,王五,2班
20230004,赵六,3班
20230005,孙七,3班
```

- **id** — Student ID, used as the unique identifier
- **name** — Student name (Chinese supported; pinyin auto-generated)
- **group** — Class/group designation

The default file is `classroom-default-students-file` (`students.csv` under `user-emacs-directory`, so data survives package upgrades). You can select a different file interactively when prompted.

---

## Usage

### Starting the System

| Command | Description |
|---------|-------------|
| `M-x classroom-start` | Start the classroom system. Prompts to restore previous state if found |
| `M-x classroom-load-csv` | Manually reload the student roster CSV |
| `M-x classroom-load-state` | Manually restore the last saved classroom state |

### Call Flow

1. Press `c` (`classroom-call`) to initiate a call
2. A rolling animation displays randomly cycling student names
3. The final selected student is shown full-screen
4. If TTS is enabled, the system speaks "Please, [Name], answer the question" in Chinese
5. The teacher enters a grade (0–4) or cancels (c)

### Grading Rubric

| Key | Level | Description |
|-----|-------|-------------|
| `0` | No Answer | Student did not respond |
| `1` | Wrong answer, no/illogical explanation | Both answer and reasoning are incorrect |
| `2` | Correct answer, no/illogical explanation | Answer is right but can't explain why |
| `3` | Correct answer with logical explanation, OR wrong answer with logical reasoning | Clear thinking matters more than correctness |
| `4` | Overturns existing conclusions and proposes new ideas | Critical thinking beyond the standard answer |
| `c` | Cancel | Cancel this call and return student to the pool |

### Keyboard Shortcuts

The following shortcuts are available in the `*Classroom Call*` buffer (provided by `classroom-mode`):

| Key | Command | Description |
|-----|---------|-------------|
| `c` | `classroom-call` | Call on a student |
| `s` | `classroom-show-statistics` | Show statistics and grade distribution chart |
| `p` | `classroom-show-pool` | Display remaining students in the current round |
| `t` | `classroom-precache-tts` | Pre-generate all TTS voice caches |
| `T` | `classroom-preheat-tts` | Background TTS cache warm-up (runs when idle) |
| `C` | `classroom-clear-tts-cache` | Clear the TTS cache directory |

### Statistics & Charts

Press `s` or run `M-x classroom-show-statistics` to view:

- Current round number and remaining/answered counts
- Per-class grade distribution bar chart (counts for levels 0–4)
- Per-class average score line (score mapping: 0→0, 1→60, 2→80, 3→98, 4→100)
- Overall average score reference line
- List of currently postponed (no-answer) students

Charts are generated by Python (matplotlib) and saved as PNG images, displayed inline in an Org buffer.

### CSV Export

Run `M-x classroom-export-csv` to export all call records as CSV:

```csv
姓名,学号,班级,Round1,Round2,Round3
张三,20230001,1班,3,0,1
李四,20230002,2班,1,0,1
...
```

Each round's grade is represented as a number (0–4). Unattended rounds are left blank. Suitable for further analysis in Excel / Google Sheets.

---

## TTS Voice Announcements

The system uses Microsoft Edge TTS for speech synthesis:

- **Student call**: "Please, [Name], answer the question" (in Chinese)
- **Grade announcement**: reads out the grade description (e.g., "Correct answer with logical explanation")

### Caching

Synthesized audio files are cached in `classroom-tts-cache-dir` using MD5-hashed filenames. Identical text is never synthesized twice.

### Warm-Up

It is recommended to press `t` (`classroom-precache-tts`) before class starts to pre-generate all voice files and avoid latency during calls. The `classroom-start` command also automatically initiates a background warm-up.

### TTS Customization

| Option | Default | Description |
|--------|---------|-------------|
| `classroom-enable-tts` | `t` | Enable/disable TTS |
| `classroom-tts-voice` | `"zh-CN-XiaoxiaoNeural"` | Edge-TTS voice name |
| `classroom-tts-rate` | `"+50%"` | Speech rate (`"+0%"` for normal) |
| `classroom-tts-player-command` | `'("mpv" "--volume-max=200")` | Audio player command |

---

## Persistence & State Recovery

Classroom state is automatically saved to `classroom-state.el`, including:

- Current round number
- Current call pool (remaining students and their order)
- Complete grading history
- Student roster
- Last cancelled student ID
- No-answer cumulative counts
- Postponed (unanswered) student list

State is saved after every grading action. On the next launch, the system asks whether to restore the previous state.

---

## No-Answer Handling

When a student does not answer (grade 0):

1. **1st–2nd no-answer**: The student is placed in `classroom-unanswered-pool` and postponed to the next session (re-added to the pool on next startup)
2. **3rd no-answer**: The student is permanently removed from the current round's call pool
3. If the student later gives a valid answer (grades 1–4), their no-answer count and postponed status are cleared

This mechanism ensures that non-responding students get another chance in future sessions without being able to evade indefinitely.

---

## Customization

All customizable options are available via `M-x customize-group RET classroom-call RET` or can be set manually:

```elisp
;; File paths
(setq classroom-directory "/path/to/classroom-call/")
(setq classroom-org-file "/path/to/classroom-record.org")
(setq classroom-state-file "/path/to/classroom-state.el")
(setq classroom-default-students-file "/path/to/students.csv")
(setq classroom-stats-image-file "/path/to/stats.png")
(setq classroom-export-csv-default-file "/path/to/grades.csv")

;; TTS settings
(setq classroom-enable-tts nil)              ; Disable voice
(setq classroom-tts-voice "zh-CN-YunxiNeural")
(setq classroom-tts-rate "+30%")
(setq classroom-tts-player-command '("ffplay" "-nodisp" "-autoexit" "-loglevel" "quiet"))

;; Roll animation / TTS concurrency / CSV
(setq classroom-roll-duration 2.5)           ; roll animation seconds (C-u c skips it)
(setq classroom-tts-max-concurrent 2)        ; concurrent TTS generation processes
(setq classroom-csv-skip-header t)           ; whether the roster CSV has a header
(setq classroom-export-csv-add-bom nil)      ; prepend UTF-8 BOM (enable for Excel/Windows)
```

---

## File Overview

| File | Description |
|------|-------------|
| `classroom-call.el` | Core source (calling, grading, TTS, statistics, export) |
| `classroom-plot.py` | Python chart generation script (matplotlib) |
| `classroom-record.org` | Call records (auto-generated, Org format) |
| `classroom-state.el` | Persistent state file (auto-generated) |
| `classroom-grades.csv` | Exported grade CSV (default filename) |
| `classroom-stats.png` | Statistics chart (auto-generated) |
| `classroom-tts-cache/` | TTS voice cache directory (auto-generated) |
| `students.csv` | Sample student roster |

---

## License

GPL-3.0
