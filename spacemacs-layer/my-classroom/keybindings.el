;;; keybindings.el --- my-classroom layer keybindings file for Spacemacs
;;
;; Copyright (c) 2025
;; Author: YanshuoChu
;; License: GPL-3.0

;; ── my-classroom global leader keybindings ──
;;
;; All shortcuts use the SPC a c prefix (SPC → application → classroom):
;;
;;   SPC a c s  →  classroom-start           启动课堂系统 / 恢复状态
;;   SPC a c c  →  classroom-call            开始点名（随机抽取学生）
;;   SPC a c p  →  classroom-show-pool       显示剩余学生池
;;   SPC a c S  →  classroom-show-statistics 显示统计与成绩分布图
;;   SPC a c t  →  classroom-precache-tts    预生成全部 TTS 缓存
;;   SPC a c T  →  classroom-preheat-tts     后台空闲时预热 TTS
;;   SPC a c C  →  classroom-clear-tts-cache 清空 TTS 缓存
;;   SPC a c l  →  classroom-load-csv        加载学生名单 CSV
;;   SPC a c e  →  classroom-export-csv      导出成绩 CSV
;;   SPC a c r  →  classroom-load-state      手动恢复课堂状态

(spacemacs/set-leader-keys
  "acs"  'classroom-start
  "acc"  'classroom-call
  "acp"  'classroom-show-pool
  "acS"  'classroom-show-statistics
  "act"  'classroom-precache-tts
  "acT"  'classroom-preheat-tts
  "acC"  'classroom-clear-tts-cache
  "acl"  'classroom-load-csv
  "ace"  'classroom-export-csv
  "acr"  'classroom-load-state)

;; ── classroom-mode local keybindings ──
;;
;; When inside the *Classroom Call* buffer, classroom-mode provides
;; single-key shortcuts (no leader prefix needed):
;;
;;   c  →  classroom-call            点名
;;   s  →  classroom-show-statistics 统计
;;   p  →  classroom-show-pool       查看剩余学生
;;   t  →  classroom-precache-tts    预生成 TTS
;;   T  →  classroom-preheat-tts     预热 TTS
;;   C  →  classroom-clear-tts-cache 清空 TTS
;;
;; These are defined in `classroom-mode-map` by the package itself.
