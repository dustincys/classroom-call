;;; classroom-call.el --- Classroom random call system with TTS  -*- lexical-binding: t; -*-
;; Copyright (c) 2026
;; Author: YanshuoChu
;; Maintainer: YanshuoChu
;; Version: 1.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/dustincys/classroom-call
;; Keywords: classroom, education, org, tts

;;; Commentary:

;; A classroom random call system for Emacs: randomly picks students
;; from a pool, announces names and grades via Edge-TTS, records
;; grades in Org mode, renders per-class statistics charts, and
;; exports grades to CSV.
;;
;; Main entry point: `classroom-start'.  Inside the *Classroom Call*
;; buffer, `classroom-mode' provides single-key commands (see
;; `classroom-mode-map').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'org-element)

(declare-function org-display-inline-images "org" (&optional include-linked refresh))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Config
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgroup classroom-call nil
  "Classroom random call system."
  :group 'applications)

(defcustom classroom-directory
  (file-name-as-directory user-emacs-directory)
  "Base directory for classroom data files.
Defaults to `user-emacs-directory' so that records and state survive
package upgrades and stay writable (never the package install dir)."
  :type 'directory
  :group 'classroom-call)

(defcustom classroom-org-file
  (expand-file-name "classroom-record.org" classroom-directory)
  "Org record file where all grades and roll calls are saved."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-state-file
  (expand-file-name "classroom-state.el" classroom-directory)
  "Persistent state file (current round, pool, history)."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-default-students-file
  (expand-file-name "students.csv" classroom-directory)
  "Default CSV file to load student list from (can be changed interactively)."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-stats-image-file
  (expand-file-name "classroom-stats.png" classroom-directory)
  "Path where the statistics chart image will be saved."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-export-csv-default-file
  (expand-file-name "classroom-grades.csv" classroom-directory)
  "Default CSV file for exporting grades (can be overridden interactively)."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-tts-cache-dir
  (expand-file-name "classroom-tts-cache/" classroom-directory)
  "Directory to cache generated TTS audio files."
  :type 'directory
  :group 'classroom-call)

(defcustom classroom-plot-script
  (expand-file-name "classroom-plot.py" classroom-directory)
  "Python script for generating grade distribution charts."
  :type 'file
  :group 'classroom-call)

(defcustom classroom-python-path
  "python3"
  "Path to the Python interpreter."
  :type 'string
  :group 'classroom-call)

(defcustom classroom-enable-tts t
  "Enable TTS (text-to-speech) during roll call."
  :type 'boolean
  :group 'classroom-call)

(defcustom classroom-tts-voice
  "zh-CN-XiaoxiaoNeural"
  "Edge TTS voice name."
  :type 'string
  :group 'classroom-call)

(defcustom classroom-tts-rate
  "+50%"
  "Speech rate for TTS (e.g., '+0%' for normal, '+50%' for faster)."
  :type 'string
  :group 'classroom-call)

(defcustom classroom-tts-player-command
  '("mpv" "--volume-max=200")
  "Command list to play an audio file.
The file path will be appended to this list.  Example: (\"mpv\"
\"--really-quiet\") or (\"ffplay\" \"-nodisp\" \"-autoexit\"
\"-loglevel\" \"quiet\")"
  :type '(repeat string)
  :group 'classroom-call)

(defcustom classroom-tts-max-concurrent 2
  "Maximum number of simultaneous TTS generation processes."
  :type 'integer
  :group 'classroom-call)

(defcustom classroom-roll-duration 2.5
  "Duration of the rolling name animation, in seconds.
A prefix argument to `classroom-call' (\\[universal-argument]) skips
the animation entirely."
  :type 'number
  :group 'classroom-call)

(defcustom classroom-grade-menu-max-height 0.9
  "Maximum height of the grading menu, as a fraction of the frame height.
The menu is 11 lines tall; the minibuffer grows to show it fully.
Raise this value if the menu is truncated on small frames, or lower
it to keep the minibuffer compact."
  :type 'number
  :group 'classroom-call)

(defcustom classroom-csv-skip-header t
  "Whether to skip the first line of a student CSV file."
  :type 'boolean
  :group 'classroom-call)

(defcustom classroom-export-csv-add-bom nil
  "Whether to prepend a UTF-8 BOM to exported CSV files.
Enable this if the CSV is opened with Excel on Windows, which may
otherwise mis-detect the encoding of Chinese text."
  :type 'boolean
  :group 'classroom-call)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Runtime Variables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar classroom-students nil
  "List of student plists loaded from the CSV file.")
(defvar classroom-current-pool nil
  "Remaining students of the current round, in draw order.")
(defvar classroom-history nil
  "List of grading records for the current session.")
(defvar classroom-round 1
  "Current round number (unique within the record file).")
(defvar classroom-last-cancelled-id nil
  "ID of the last cancelled student, to avoid immediate repeat.")
(defvar classroom-unanswered-pool nil
  "Students postponed to the next session (absent / 挂起).")

;; Internal, non-persisted state.
(defvar classroom--random-seeded nil
  "Non-nil once the random generator has been seeded.")
(defvar classroom--roll-timer nil
  "Timer object of the running roll animation.")
(defvar classroom--roll-frames 0
  "Frames remaining in the roll animation.")
(defvar classroom--roll-callback nil
  "Function called when the roll animation finishes.")
(defvar classroom--tts-queue nil
  "Pending TTS generation tasks: (text file play-when-done).")
(defvar classroom--tts-running 0
  "Number of TTS generation processes currently running.")
(defvar classroom--tts-seq 0
  "Sequence counter used to name TTS generation processes.")
(defvar classroom--tts-batch-pending nil
  "Non-nil while a precache batch is still being generated.")
(defvar classroom--player-proc nil
  "Process object of the current audio player.")
(defvar classroom--stats-inline-timer nil
  "Idle timer used to display inline images in the statistics buffer.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Random Seed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--ensure-random-seed ()
  "Seed the random number generator, once per Emacs session."
  (unless classroom--random-seeded
    (random t)
    (setq classroom--random-seeded t)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Score Levels
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst classroom-score-levels
  '(("0" . "无回答")
    ("1" . "回答错误且无解释或解释无逻辑")
    ("2" . "回答正确，但无解释或解释无逻辑")
    ("3" . "回答正确解释有逻辑，或回答错误但解释很有逻辑")
    ("4" . "推翻已有结论并提出新观点"))
  "Scoring rubric as (KEY . LABEL) pairs, lowest to highest.
This is the single source of truth: the grading prompt, chart labels
and TTS texts are all derived from it.")

(defun classroom-score-level-label (key)
  "Return the rubric LABEL for KEY, or KEY itself if unknown."
  (or (cdr (assoc key classroom-score-levels)) key))

(defun classroom-score-level-key (label)
  "Return the rubric key for LABEL, or nil if not found."
  (car (rassoc label classroom-score-levels)))

(defun classroom-score-level-labels ()
  "Return the list of rubric labels."
  (mapcar #'cdr classroom-score-levels))

(defcustom classroom-score-points
  '(("0" . 0) ("1" . 60) ("2" . 80) ("3" . 98) ("4" . 100))
  "Points awarded per rubric key.
Used in the grading prompt and passed to the chart script, so the
two always stay in sync."
  :type '(alist :key-type string :value-type integer)
  :group 'classroom-call)

(defun classroom-score-level-points (key)
  "Return the points for rubric KEY, or nil if unknown."
  (cdr (assoc key classroom-score-points)))

(defun classroom--grade-prompt ()
  "Return the complete multi-line grading prompt.
Lines are ordered: highest-scoring answer first, lowest last, then
无回答, 挂起 and 取消.  The full menu is 11 lines tall."
  (let ((lines (mapcar
                (lambda (pair)
                  (let ((key (car pair)))
                    (format "%s %s（%d分）"
                            key
                            (classroom-score-level-label key)
                            (or (classroom-score-level-points key) 0))))
                (reverse classroom-score-levels))))
    (mapconcat #'identity
               (append '("=== 评分选项 ===")
                       lines
                       '(""
                         "a 挂起（未到课，推迟到下次）"
                         "c 取消本次提问"
                         ""
                         "评分: "))
               "\n")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pinyin
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst classroom--pinyin-script
  (concat
   "import sys\n"
   "from pypinyin import lazy_pinyin, Style\n"
   "for name in sys.argv[1].split('\\n'):\n"
   "    py = ' '.join(w.capitalize() for w in lazy_pinyin(name, style=Style.TONE))\n"
   "    print(name + '\\t' + py)\n")
  "Python snippet converting newline-separated names to pinyin.
Prints one `name<TAB>pinyin' line per input name.")

(defun classroom--ascii-name-p (name)
  "Return non-nil when NAME consists only of ASCII characters."
  (string-match-p "\\`[[:ascii:]]+\\'" name))

(defun classroom--pinyin-batch (names)
  "Return pinyin for NAMES using a single Python invocation.
ASCII names are passed through unchanged; if the conversion fails the
original names are returned and a message is shown."
  (let ((to-convert (cl-remove-if #'classroom--ascii-name-p names)))
    (if (null to-convert)
        names
      (let ((mapping (make-hash-table :test 'equal)))
        (with-temp-buffer
          (let ((ret (call-process
                      classroom-python-path nil (list (current-buffer) nil) nil
                      "-c" classroom--pinyin-script
                      (mapconcat #'identity to-convert "\n"))))
            (when (eq ret 0)
              (dolist (line (split-string (buffer-string) "\n" t))
                (when (string-match "\\(.*\\)\t\\(.*\\)" line)
                  (puthash (match-string 1 line) (match-string 2 line) mapping))))
            (unless (eq ret 0)
              (message "拼音转换失败（退出码 %d），使用原名" ret))))
        (mapcar (lambda (n) (gethash n mapping n)) names)))))

(defun classroom-name-pinyin (name)
  "Convert Chinese NAME to pinyin with tones.
ASCII names are returned unchanged; on conversion failure NAME is
returned as-is."
  (if (classroom--ascii-name-p name)
      name
    (car (classroom--pinyin-batch (list name)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Student Formatting
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-format-student (student &optional highlight)
  "Format STUDENT compactly: name (pinyin) then id + group on one line.
Wrap the name in >>> ... <<< when HIGHLIGHT is non-nil."
  (format "%s%s (%s)%s\n%s %s"
          (if highlight ">>> " "")
          (plist-get student :name)
          (plist-get student :pinyin)
          (if highlight " <<<" "")
          (plist-get student :id)
          (plist-get student :group)))

(defun classroom-student-line (student)
  "One line student info for STUDENT."
  (format "%s (%s) [%s] <%s>"
          (plist-get student :name)
          (plist-get student :pinyin)
          (plist-get student :id)
          (plist-get student :group)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CSV Loading
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--split-csv-line (line)
  "Split CSV LINE into trimmed fields, honoring double-quoted fields."
  (let ((fields nil)
        (field "")
        (in-quotes nil)
        (i 0)
        (len (length line)))
    (while (< i len)
      (let ((ch (aref line i)))
        (cond
         ((and in-quotes (eq ch ?\")
               (or (= (1+ i) len) (not (eq (aref line (1+ i)) ?\"))))
          (setq in-quotes nil))
         ((and in-quotes (eq ch ?\"))
          (setq field (concat field "\"")
                i (1+ i)))
         ((eq ch ?\")
          (setq in-quotes t))
         ((and (not in-quotes) (eq ch ?,))
          (push field fields)
          (setq field ""))
         (t
          (setq field (concat field (string ch))))))
      (setq i (1+ i)))
    (push field fields)
    (mapcar #'string-trim (nreverse fields))))

(defun classroom-load-csv (file)
  "Load students from CSV FILE (columns: id,name,group)."
  (interactive (list (read-file-name "CSV file: "
                                     (file-name-directory classroom-default-students-file)
                                     nil nil
                                     (file-name-nondirectory classroom-default-students-file))))
  (unless (file-readable-p file)
    (user-error "无法读取文件 %s" file))
  (let ((rows nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (when classroom-csv-skip-header
        (forward-line 1))
      (while (not (eobp))
        (let* ((line (string-trim
                      (buffer-substring-no-properties
                       (line-beginning-position)
                       (line-end-position))))
               (parts (classroom--split-csv-line line)))
          (when (>= (length parts) 3)
            (push (list (nth 0 parts) (nth 1 parts) (nth 2 parts)) rows)))
        (forward-line 1)))
    (setq rows (nreverse rows))
    (let ((pinyins (classroom--pinyin-batch (mapcar #'cadr rows))))
      (setq classroom-students
            (cl-mapcar (lambda (row py)
                         `(:id ,(nth 0 row) :name ,(nth 1 row)
                               :pinyin ,py :group ,(nth 2 row)))
                       rows pinyins))))
  (classroom-reset-pool)
  (classroom-save-state)
  (message "Loaded %d students" (length classroom-students)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Shuffle
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-shuffle (list)
  "Shuffle LIST."
  (classroom--ensure-random-seed)
  (let ((vec (vconcat list)))
    (cl-loop for i from (1- (length vec)) downto 1
             do (cl-rotatef (aref vec i) (aref vec (random (1+ i)))))
    (append vec nil)))

(defun classroom-reset-pool ()
  "Reset pool for a new round."
  (setq classroom-current-pool
        (classroom-shuffle classroom-students)))

(defun classroom-next-student ()
  "Get next student, starting a new round if needed.
Avoids immediately repeating the last cancelled student, unless they
are the only one left in the pool."
  ;; If pool empty, advance round and reset.
  (when (null classroom-current-pool)
    (setq classroom-round (1+ classroom-round))
    (classroom-reset-pool)
    (message "=== 第 %d 轮开始 ===" classroom-round))
  (let ((pool classroom-current-pool)
        (cancel-id classroom-last-cancelled-id))
    (when (and cancel-id (> (length pool) 1)
               (equal (plist-get (car pool) :id) cancel-id))
      (let ((swap (cl-loop for i from 1 below (length pool)
                           when (not (equal (plist-get (nth i pool) :id) cancel-id))
                           return i)))
        (when swap
          (cl-rotatef (nth 0 pool) (nth swap pool)))))
    (pop classroom-current-pool)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Persistent State
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--state-data ()
  "Return the current persistent state as a plist."
  (list :round classroom-round
        :pool classroom-current-pool
        :history classroom-history
        :students classroom-students
        :last-cancelled classroom-last-cancelled-id
        :unanswered-pool classroom-unanswered-pool))

(defun classroom--restore-state (data)
  "Restore state variables from DATA plist."
  (setq classroom-round (or (plist-get data :round) 1)
        classroom-current-pool (plist-get data :pool)
        classroom-history (plist-get data :history)
        classroom-students (plist-get data :students)
        classroom-last-cancelled-id (plist-get data :last-cancelled)
        classroom-unanswered-pool (plist-get data :unanswered-pool)))

(defun classroom-save-state ()
  "Save persistent state as a data file (never executable code)."
  (make-directory (file-name-directory classroom-state-file) t)
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file classroom-state-file
      (insert ";;; classroom persistent state (data file, do not edit)\n\n")
      (prin1 (list 'classroom--state-data (classroom--state-data)) (current-buffer)))))

(defun classroom--read-state-data ()
  "Read the state plist from the state file, or nil if unusable."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents classroom-state-file)
        (let ((form (read (current-buffer))))
          (when (and (consp form) (eq (car form) 'classroom--state-data))
            (nth 1 form))))
    (error nil)))

(defun classroom-load-state ()
  "Load persistent state, merging unanswered students back into pool.
Old-format (executable) state files are migrated to the data format
on first load."
  (interactive)
  (if (not (file-exists-p classroom-state-file))
      (message "未发现课堂状态文件")
    (let ((data (classroom--read-state-data)))
      (unless data
        ;; Legacy state file written as executable `setq' forms: load it
        ;; once (one-time migration) and re-save in the data format.
        (condition-case err
            (progn
              (load-file classroom-state-file)
              (message "已将旧格式状态文件迁移为数据格式"))
          (error (message "状态文件读取失败：%s" (error-message-string err)))))
      (when data
        (classroom--restore-state data))
      ;; Put postponed students back into the draw pool.
      (when classroom-unanswered-pool
        (setq classroom-current-pool
              (classroom-shuffle (append classroom-current-pool classroom-unanswered-pool)))
        (message "已将 %d 名挂起学生放回点名池" (length classroom-unanswered-pool))
        (setq classroom-unanswered-pool nil))  ; clear after merging
      (classroom-save-state)                  ; persist the merge immediately
      (message "课堂状态已恢复"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; UI
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-buffer ()
  "Return the classroom display buffer, initializing it once."
  (let ((buf (get-buffer-create "*Classroom Call*")))
    (unless (eq (buffer-local-value 'major-mode buf) 'special-mode)
      (with-current-buffer buf
        (special-mode)))
    buf))

(defun classroom-answered-count ()
  "Number of students no longer in the current pool."
  (- (length classroom-students) (length classroom-current-pool)))

(defun classroom-render (text &optional switch)
  "Render TEXT in the classroom buffer, left-aligned and compact.
TEXT is a two-line student description (name / id+group): the header
and detail lines use a small face, the student name is prominent.
Switch to the buffer first if SWITCH is non-nil."
  (with-current-buffer (classroom-buffer)
    (let ((inhibit-read-only t)
          (lines (split-string text "\n")))
      (erase-buffer)
      (insert (propertize
               (format "课堂提问系统 第 %d 轮（剩余 %d 人，已回答 %d 人）\n\n"
                       classroom-round
                       (length classroom-current-pool)
                       (classroom-answered-count))
               'face '(:height 1.1 :weight bold)))
      (when (car lines)
        (insert (propertize (car lines) 'face '(:height 2.0 :weight bold)))
        (insert "\n"))
      (when (cdr lines)
        (insert (propertize (mapconcat #'identity (cdr lines) "  ")
                            'face '(:height 0.9 :foreground "gray50")))))
    (goto-char (point-min)))
  (when switch
    (switch-to-buffer (classroom-buffer)))
  (redisplay))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Rolling Animation
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-roll-animation (&optional duration)
  "Start the rolling name animation for DURATION seconds.
DURATION defaults to `classroom-roll-duration'.  The animation runs
on a timer so the UI stays responsive; when it finishes,
`classroom--roll-callback' is invoked with no arguments."
  (classroom--roll-cancel)
  (setq classroom--roll-frames
        (max 1 (round (/ (or duration classroom-roll-duration) 0.05))))
  (setq classroom--roll-timer
        (run-with-timer 0 0.05 #'classroom--roll-tick)))

(defun classroom--roll-tick ()
  "Advance the rolling animation by one frame."
  (if (<= classroom--roll-frames 0)
      (classroom--roll-finish)
    (setq classroom--roll-frames (1- classroom--roll-frames))
    (classroom--ensure-random-seed)
    (let* ((pool (or classroom-current-pool classroom-students))
           (student (when pool (nth (random (length pool)) pool))))
      (when student
        (classroom-render (classroom-format-student student) nil)))))

(defun classroom--roll-cancel ()
  "Cancel a running roll animation without invoking the callback."
  (when classroom--roll-timer
    (cancel-timer classroom--roll-timer)
    (setq classroom--roll-timer nil)))

(defun classroom--roll-finish ()
  "Finish the roll animation and run the continuation callback."
  (classroom--roll-cancel)
  (let ((cb classroom--roll-callback))
    (setq classroom--roll-callback nil)
    (when cb (funcall cb))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Grade
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-grade-student ()
  "Grade the current student, returning the grade label, \\='hang or \\='cancel."
  (redisplay)
  (let* ((keys (mapcar #'car (reverse classroom-score-levels)))
         (choices (append (mapcar (lambda (k) (string-to-char k)) keys) '(?a ?c)))
         ;; Let the minibuffer grow so the full multi-line menu is shown.
         (max-mini-window-height classroom-grade-menu-max-height)
         (read-char-choice-use-read-key nil)
         (choice (read-char-choice (classroom--grade-prompt) choices)))
    (redisplay)
    (cond ((eq choice ?c) 'cancel)
          ((eq choice ?a) 'hang)
          (t (classroom-score-level-label (char-to-string choice))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Org Record
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-save-record (student grade)
  "Save STUDENT and GRADE to `classroom-org-file'."
  (make-directory (file-name-directory classroom-org-file) t)
  (let ((coding-system-for-write 'utf-8))
    (with-temp-buffer
      (insert (format "\n* 第%d轮 %s\n" classroom-round (classroom-student-line student)))
      (insert ":PROPERTIES:\n")
      (insert (format ":ID: %s\n" (plist-get student :id)))
      (insert (format ":NAME: %s\n" (plist-get student :name)))
      (insert (format ":PINYIN: %s\n" (plist-get student :pinyin)))
      (insert (format ":GROUP: %s\n" (plist-get student :group)))
      (insert (format ":GRADE: %s\n" grade))
      (insert (format ":TIME: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M:%S]")))
      (insert ":END:\n\n")
      (append-to-file (point-min) (point-max) classroom-org-file))))

(defun classroom--check-record-savable ()
  "Signal an error if the record file has unsaved modifications."
  (let ((buf (get-file-buffer classroom-org-file)))
    (when (and buf (buffer-modified-p buf))
      (user-error "记录文件 %s 有未保存修改，请先保存该缓冲区" classroom-org-file))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; History
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-add-history (student grade)
  "Add STUDENT and GRADE to history."
  (push (list :id (plist-get student :id)
              :name (plist-get student :name)
              :pinyin (plist-get student :pinyin)
              :group (plist-get student :group)
              :grade grade
              :round classroom-round
              :time (format-time-string "%Y-%m-%d %H:%M:%S"))
        classroom-history))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Statistics & Chart
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--generate-chart (class-data output-file)
  "Generate chart using Python script and CLASS-DATA, save to OUTPUT-FILE."
  (let* ((labels (classroom-score-level-labels))
         (classes (mapcar #'car class-data))
         (data (vconcat (mapcar (lambda (c) (vconcat (append (cdr c) nil))) class-data)))
         (scores (vconcat (mapcar (lambda (pair)
                                    (or (classroom-score-level-points (car pair)) 0))
                                  classroom-score-levels)))
         (json-file (make-temp-file "classroom-data-" nil ".json"))
         (json-str (json-encode `((labels . ,(vconcat labels))
                                  (classes . ,(vconcat classes))
                                  (data . ,data)
                                  (scores . ,scores))))
         (err-buf (get-buffer-create "*classroom-chart-debug*"))
         ret)
    (with-temp-file json-file
      (insert json-str))
    (setq ret (call-process classroom-python-path nil (list err-buf t) nil
                            classroom-plot-script
                            json-file
                            output-file))
    (delete-file json-file)
    (if (not (eq ret 0))
        (error "图表生成失败，退出码 %d，查看 *classroom-chart-debug* 缓冲区。stderr:\n%s"
               ret (with-current-buffer err-buf (buffer-string)))
      (message "图表已生成: %s" output-file))))

(defun classroom-show-statistics ()
  "Show classroom statistics with per-class grade distribution chart."
  (interactive)
  (let* ((remaining (length classroom-current-pool))
         (answered (classroom-answered-count))
         (n-levels (length (classroom-score-level-labels)))
         (level-index (make-hash-table :test 'equal))
         (class-dist (make-hash-table :test 'equal))
         classes)
    ;; Map grade label -> level index once.
    (cl-loop for pair in classroom-score-levels
             for i from 0
             do (puthash (cdr pair) i level-index))
    ;; Aggregate per-class grades.
    (dolist (entry classroom-history)
      (let* ((grade (plist-get entry :grade))
             (group (or (plist-get entry :group) "未知班级"))
             (vec (gethash group class-dist)))
        (unless vec
          (setq vec (make-vector n-levels 0))
          (puthash group vec class-dist)
          (push group classes))
        (let ((idx (gethash grade level-index -1)))
          (when (>= idx 0)
            (aset vec idx (1+ (aref vec idx)))))))
    (setq classes (sort classes #'string<))
    (let* ((class-data (mapcar (lambda (c) (cons c (gethash c class-dist))) classes))
           (chart-file (and class-data classroom-stats-image-file)))
      ;; Generate chart (skip when there is no data at all).
      (when chart-file
        (condition-case err
            (classroom--generate-chart class-data chart-file)
          (error (message "无法生成图表：%s" (error-message-string err))
                 (setq chart-file nil))))
      ;; Prepare Org buffer.
      (with-current-buffer (get-buffer-create "*Classroom Statistics*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (org-mode)
          (insert (format "* 课堂统计（第 %d 轮）\n\n" classroom-round))
          (insert (format "- 剩余人数：%d\n" remaining))
          (insert (format "- 已回答人数：%d\n\n" answered))
          (if (and chart-file (file-exists-p chart-file))
              (insert "** 成绩分布图\n\n"
                      (format "[[file:%s]]\n\n" chart-file))
            (insert (if class-data
                        "** 成绩分布（图表生成失败）\n\n"
                      "** 成绩分布（暂无数据）\n\n")))
          ;; Current postponed (no-answer) students.
          (insert "** 当前无回答（挂起）学生\n\n")
          (if (null classroom-unanswered-pool)
              (insert "无\n")
            (dolist (student classroom-unanswered-pool)
              (insert "- " (classroom-student-line student) "\n"))))
        (goto-char (point-min)))
      (pop-to-buffer "*Classroom Statistics*")
      ;; Display inline image after buffer is ready.
      (when (and chart-file (file-exists-p chart-file))
        (when classroom--stats-inline-timer
          (cancel-timer classroom--stats-inline-timer))
        (setq classroom--stats-inline-timer
              (run-with-idle-timer 0.1 nil
                                   (lambda ()
                                     (with-current-buffer "*Classroom Statistics*"
                                       (org-display-inline-images t t)))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; TTS (Edge-TTS + Cache)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-tts-file (text)
  "Return TTS cache file path for TEXT."
  (expand-file-name
   (concat (md5 (concat classroom-tts-voice classroom-tts-rate text)) ".mp3")
   classroom-tts-cache-dir))

(defun classroom--tts-enqueue (text &optional play-when-done)
  "Enqueue async TTS generation for TEXT.
Play the result when ready if PLAY-WHEN-DONE is non-nil."
  (make-directory classroom-tts-cache-dir t)
  (let ((file (classroom-tts-file text)))
    (unless (file-exists-p file)
      (let ((existing (cl-member text classroom--tts-queue :key #'car :test #'equal)))
        (if existing
            ;; Already queued: just record that we want it played.
            (when play-when-done
              (setf (nth 2 (car existing)) t))
          (push (list text file play-when-done) classroom--tts-queue)))
      (classroom--tts-pump))))

(defun classroom--tts-pump ()
  "Start queued TTS generation processes up to the concurrency limit."
  (while (and classroom--tts-queue
              (< classroom--tts-running classroom-tts-max-concurrent))
    (let ((task (pop classroom--tts-queue)))
      (setq classroom--tts-running (1+ classroom--tts-running))
      (classroom--tts-start-process (nth 0 task) (nth 1 task) (nth 2 task)))))

(defun classroom--tts-start-process (text file play-when-done)
  "Start an async edge-tts process writing TEXT to FILE.
Generates into a temp file and renames it on success, so a failed or
interrupted run never leaves a corrupt file in the cache.  Plays the
result when ready if PLAY-WHEN-DONE is non-nil."
  (let* ((tmp (make-temp-file (expand-file-name "classroom-tts-" classroom-tts-cache-dir)
                              nil ".mp3"))
         (proc (make-process
                :name (format "classroom-tts-gen-%d" (cl-incf classroom--tts-seq))
                :buffer (get-buffer-create "*TTS-log*")
                :command (list "edge-tts"
                               "--voice" classroom-tts-voice
                               (format "--rate=%s" classroom-tts-rate)
                               "--text" text
                               "--write-media" tmp)
                :sentinel (lambda (p _event)
                            (classroom--tts-on-finish p text file tmp play-when-done)))))
    (set-process-query-on-exit-flag proc nil)))

(defun classroom--tts-on-finish (proc text file tmp play-when-done)
  "Handle completion of PROC for TEXT.
Renames TMP to FILE on success, deletes it on failure, and plays the
result when PLAY-WHEN-DONE is non-nil."
  (setq classroom--tts-running (max 0 (1- classroom--tts-running)))
  (if (= (process-exit-status proc) 0)
      (progn
        (rename-file tmp file t)          ; atomic: never cache a partial file
        (when play-when-done
          (classroom-play-tts file)))
    (progn
      (ignore-errors (delete-file tmp))
      (message "TTS 生成失败: %s (查看 *TTS-log*)" text)))
  (classroom--tts-pump)
  (when (and classroom--tts-batch-pending
             (null classroom--tts-queue)
             (zerop classroom--tts-running))
    (setq classroom--tts-batch-pending nil)
    (message "TTS 缓存预生成完成")))

(defun classroom-play-tts (file)
  "Play TTS FILE using customizable player command.
Errors are suppressed so audio playback failure never blocks the
grading menu."
  (when (and (file-exists-p file)
             (executable-find (car classroom-tts-player-command)))
    (when (and classroom--player-proc (process-live-p classroom--player-proc))
      (ignore-errors (kill-process classroom--player-proc)))
    (setq classroom--player-proc
          (ignore-errors
            (apply #'start-process
                   "classroom-tts-player"
                   nil
                   (append classroom-tts-player-command (list file)))))))

(defun classroom-speak (text)
  "Speak TEXT using cached TTS, generating asynchronously if not cached.
Returns immediately; the menu is never blocked on TTS generation."
  (when classroom-enable-tts
    (let ((file (classroom-tts-file text)))
      (if (file-exists-p file)
          (classroom-play-tts file)
        (classroom--tts-enqueue text t)))))

(defun classroom-precache-tts ()
  "Pre-generate all classroom TTS in the background."
  (interactive)
  (unless classroom-students
    (user-error "No students loaded"))
  (unless (executable-find "edge-tts")
    (user-error "未找到 edge-tts 可执行文件，请先安装 (pip install edge-tts)"))
  (let ((texts (append (classroom-score-level-labels)
                       (mapcar (lambda (s) (format "请 %s 回答问题" (plist-get s :name)))
                               classroom-students)))
        (missing 0))
    (dolist (text texts)
      (unless (file-exists-p (classroom-tts-file text))
        (setq missing (1+ missing))))
    (if (zerop missing)
        (message "TTS 缓存已全部存在")
      (setq classroom--tts-batch-pending t)
      (message "开始后台预生成 %d 个 TTS 文件..." missing)
      (dolist (text texts)
        (unless (file-exists-p (classroom-tts-file text))
          (classroom--tts-enqueue text))))))

(defun classroom-preheat-tts ()
  "Background TTS preheat."
  (interactive)
  (run-with-idle-timer 1 nil #'classroom-precache-tts)
  (message "后台开始预热 TTS 缓存"))

(defun classroom-clear-tts-cache ()
  "Clear TTS cache."
  (interactive)
  (when (y-or-n-p "确定清空 TTS 缓存? ")
    (delete-directory classroom-tts-cache-dir t)
    (make-directory classroom-tts-cache-dir t)
    (message "TTS 缓存已清空")))

(defun classroom-speak-current-student (student)
  "Speak STUDENT name for calling."
  (classroom-speak (format "请 %s 回答问题" (plist-get student :name))))

(defun classroom-speak-grade (grade)
  "Speak GRADE text only (without student name)."
  (classroom-speak grade))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main Flow
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-call ()
  "Main call flow."
  (interactive)
  (if classroom--roll-timer
      (message "点名动画进行中，请稍候")
    (unless classroom-students
      (if (y-or-n-p "恢复上次课堂状态? ")
          (classroom-load-state)
        (call-interactively #'classroom-load-csv)))
    (switch-to-buffer (classroom-buffer))
    (if current-prefix-arg
        (classroom--do-call)
      (setq classroom--roll-callback #'classroom--do-call)
      (classroom-roll-animation))))

(defun classroom--do-call ()
  "Pick and display the next student, then grade them."
  (classroom--check-record-savable)
  (let* ((student (classroom-next-student)))
    (unless student
      (user-error "没有剩余学生，请先加载学生名单"))
    (setq classroom-last-cancelled-id nil)
    (classroom-render (classroom-format-student student t) t)
    (classroom-speak-current-student student)
    (let ((grade (classroom-grade-student)))
      (cond
       ((eq grade 'cancel)
        ;; Misoperation: put back and avoid immediate repeat.
        (setq classroom-last-cancelled-id (plist-get student :id))
        (setq classroom-current-pool
              (classroom-shuffle (append classroom-current-pool (list student))))
        (classroom-save-state)
        (message "已取消提问，并重新随机"))

       ((eq grade 'hang)
        ;; Student did not come to class: postpone to the next session.
        (classroom--hang-student student))

       (t
        ;; Record the grade.  A no-answer (0) is recorded only and is
        ;; NOT postponed; an answered student clears any earlier
        ;; postponement (挂起) status.
        (classroom-save-record student grade)
        (classroom-add-history student grade)
        (let ((id (plist-get student :id)))
          (setq classroom-unanswered-pool
                (cl-remove-if (lambda (s) (equal (plist-get s :id) id))
                              classroom-unanswered-pool)))
        (message "%s -> %s" (classroom-student-line student) grade)
        (classroom-save-state)
        (classroom-speak-grade grade))))))

(defun classroom--hang-student (student)
  "Postpone STUDENT to the next session (absent / 挂起).
Records the call as 挂起 in the org file and history."
  (classroom-save-record student "挂起")
  (classroom-add-history student "挂起")
  (let ((id (plist-get student :id)))
    ;; Replace any earlier postponement entry to avoid duplicates.
    (setq classroom-unanswered-pool
          (cl-remove-if (lambda (s) (equal (plist-get s :id) id))
                        classroom-unanswered-pool))
    (push student classroom-unanswered-pool))
  (classroom-save-state)
  (message "%s -> 挂起（未到课，已推迟到下次点名）"
           (classroom-student-line student)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Start / Resume
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--org-max-round ()
  "Return the largest round number found in `classroom-org-file', or 0."
  (if (not (file-exists-p classroom-org-file))
      0
    (let ((max 0))
      (with-temp-buffer
        (insert-file-contents classroom-org-file)
        (goto-char (point-min))
        (while (re-search-forward "^\\* 第\\([0-9]+\\)轮" nil t)
          (setq max (max max (string-to-number (match-string 1)))))
        max))))

(defun classroom-start ()
  "Start classroom system."
  (interactive)
  (classroom--ensure-random-seed)
  (if (and (file-exists-p classroom-state-file)
           (y-or-n-p "发现课堂状态，是否恢复? "))
      (classroom-load-state)
    (progn
      ;; Continue round numbering so rounds stay unique within the
      ;; record file (otherwise CSV export would merge sessions).
      (setq classroom-round (1+ (classroom--org-max-round)))
      (setq classroom-history nil)
      (setq classroom-last-cancelled-id nil)
      (setq classroom-unanswered-pool nil)   ; fresh start
      (call-interactively #'classroom-load-csv)))
  (delete-other-windows)
  (switch-to-buffer (classroom-buffer))
  (classroom-mode 1)
  (message "课堂系统已启动")
  (classroom-preheat-tts))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pool Display
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-show-pool ()
  "Show remaining pool."
  (interactive)
  (with-current-buffer (get-buffer-create "*Classroom Pool*")
    (setq buffer-read-only nil)
    (erase-buffer)
    (insert (format "第 %d 轮剩余学生\n\n" classroom-round))
    (dolist (student classroom-current-pool)
      (insert (classroom-student-line student))
      (insert "\n"))
    (goto-char (point-min))
    (setq buffer-read-only t)
    (display-buffer (current-buffer))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Keymap & Mode
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar classroom-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'classroom-call)
    (define-key map (kbd "s") #'classroom-show-statistics)
    (define-key map (kbd "p") #'classroom-show-pool)
    (define-key map (kbd "t") #'classroom-precache-tts)
    (define-key map (kbd "T") #'classroom-preheat-tts)
    (define-key map (kbd "C") #'classroom-clear-tts-cache)
    map))

(define-minor-mode classroom-mode
  "Classroom mode."
  :lighter " Classroom"
  :keymap classroom-mode-map)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CSV Export
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--csv-escape (field)
  "Escape FIELD for RFC-4180 style CSV output."
  (if (string-match-p "[\",\n\r]" field)
      (concat "\"" (replace-regexp-in-string "\"" "\"\"" field) "\"")
    field))

(defun classroom-export-csv (&optional output-file)
  "Export grades from `classroom-org-file' to CSV.
Columns: 姓名,学号,班级,Round1,Round2,... with numeric grades 0-4.
If OUTPUT-FILE is not provided, use `classroom-export-csv-default-file'."
  (interactive (list (read-file-name "导出 CSV 到: "
                                     (file-name-directory classroom-export-csv-default-file)
                                     nil nil
                                     (file-name-nondirectory classroom-export-csv-default-file))))
  (unless output-file
    (setq output-file classroom-export-csv-default-file))
  (let* ((org-file (expand-file-name classroom-org-file))
         (records nil)
         (student-ids nil)
         (max-round 0)
         (grade-to-number
          (let ((ht (make-hash-table :test 'equal)))
            (dolist (pair classroom-score-levels)
              (puthash (cdr pair) (string-to-number (car pair)) ht))
            ht)))
    (unless (file-exists-p org-file)
      (error "记录文件 %s 不存在" org-file))
    ;; Parse Org.
    (with-temp-buffer
      (insert-file-contents org-file)
      (org-mode)
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (hl)
          (when (string-match "第\\([0-9]+\\)轮" (org-element-property :raw-value hl))
            (let* ((round (string-to-number (match-string 1 (org-element-property :raw-value hl))))
                   (id (org-element-property :ID hl))
                   (name (org-element-property :NAME hl))
                   (group (org-element-property :GROUP hl))
                   (grade-text (org-element-property :GRADE hl)))
              (when (and id name group grade-text)
                (let ((grade-num (gethash grade-text grade-to-number)))
                  (when grade-num
                    (push (list :id id :name name :group group :round round :grade grade-num) records)
                    (setq max-round (max max-round round))
                    (unless (member id student-ids)
                      (push id student-ids))))))))))
    ;; Build output.
    (let ((students-info (make-hash-table :test 'equal)))
      (dolist (r records)
        (puthash (plist-get r :id)
                 (list :name (plist-get r :name) :group (plist-get r :group))
                 students-info))
      (setq student-ids (sort student-ids #'string<))
      (let ((coding-system-for-write 'utf-8))
        (with-temp-buffer
          (when classroom-export-csv-add-bom
            (insert "\xfeff"))
          (insert (mapconcat #'classroom--csv-escape '("姓名" "学号" "班级") ","))
          (dotimes (i max-round) (insert (format ",Round%d" (1+ i))))
          (insert "\n")
          (dolist (id student-ids)
            (let* ((info (gethash id students-info))
                   (name (plist-get info :name))
                   (group (plist-get info :group))
                   (grades-by-round (make-hash-table :test 'eql)))
              (dolist (r records)
                (when (equal (plist-get r :id) id)
                  (puthash (plist-get r :round) (plist-get r :grade) grades-by-round)))
              (insert (mapconcat #'classroom--csv-escape (list name id group) ","))
              (dotimes (i max-round)
                (let ((round-num (1+ i)))
                  (insert (format ",%s" (or (gethash round-num grades-by-round) "")))))
              (insert "\n")))
          (write-region (point-min) (point-max) output-file nil 'silent)
          (message "CSV 已导出到 %s" output-file)
          (find-file output-file))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Provide
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'classroom-call)
;;; classroom-call.el ends here
