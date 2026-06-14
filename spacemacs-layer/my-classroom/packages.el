;;; packages.el --- my-classroom layer packages file for Spacemacs
;;
;; Copyright (c) 2026
;; Author: YanshuoChu
;; License: GPL-3.0

(defconst my-classroom-packages
  '(
    (classroom-call
     :location (recipe
                :fetcher github
                :repo "dustincys/classroom-call"
                :files ("*.el" "*.py")))
    )
  "The list of packages to install for the my-classroom layer.")

(defun my-classroom/init-classroom-call ()
  "Initialize classroom-call for my-classroom layer."
  (use-package classroom-call
    :defer t
    :init
    (progn
      ;; ── Directory ──
      ;; classroom-directory defaults to the package install path;
      ;; set it explicitly before the package loads so defcustom
      ;; won't override it.
      (setq classroom-directory
            (file-name-directory (locate-library "classroom-call")))
      (setq classroom-plot-script
            (expand-file-name "classroom-plot.py" classroom-directory))


      (setq classroom-data-dir
            "~/github/2026-med-data-process/")
      ;; ── File Paths ──
      (setq classroom-org-file
            (expand-file-name "classroom-record.org" classroom-data-dir))
      (setq classroom-state-file
            (expand-file-name "classroom-state.el" classroom-data-dir))
      (setq classroom-default-students-file
            (expand-file-name "students.csv" classroom-data-dir))
      (setq classroom-stats-image-file
            (expand-file-name "classroom-stats.png" classroom-data-dir))
      (setq classroom-export-csv-default-file
            (expand-file-name "classroom-grades.csv" classroom-data-dir))
      (setq classroom-tts-cache-dir
            (expand-file-name "classroom-tts-cache/" classroom-data-dir))

      ;; ── Python ──
      (setq classroom-python-path "~/miniconda3/bin/python3")

      ;; ── TTS ──
      (setq classroom-enable-tts t)
      (setq classroom-tts-voice "zh-CN-XiaoxiaoNeural")
      (setq classroom-tts-rate "+50%")
      (setq classroom-tts-player-command '("mpv" "--volume-max=200"))

      ;; Ensure TTS cache directory exists
      (unless (file-directory-p classroom-tts-cache-dir)
        (make-directory classroom-tts-cache-dir t)))
    :commands (
               classroom-call
               classroom-start
               classroom-show-statistics
               classroom-show-pool
               classroom-precache-tts
               classroom-preheat-tts
               classroom-clear-tts-cache
               classroom-load-csv
               classroom-load-state
               classroom-export-csv)))
