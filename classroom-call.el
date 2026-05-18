;;; classroom-call.el --- Classroom random call system with TTS  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Config
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgroup classroom-call nil
  "Classroom random call system."
  :group 'applications)

(defcustom classroom-org-file
  "~/classroom-record.org"
  "Org record file."
  :type 'file)

(defcustom classroom-state-file
  "~/.emacs.d/classroom-state.el"
  "Persistent state file."
  :type 'file)

(defcustom classroom-enable-tts t
  "Enable TTS (text-to-speech)."
  :type 'boolean)

(defcustom classroom-tts-voice
  "zh-CN-XiaoxiaoNeural"
  "Edge TTS voice."
  :type 'string)

(defcustom classroom-tts-rate
  "+50%"
  "Speech rate."
  :type 'string)

(defcustom classroom-tts-cache-dir
  "~/.emacs.d/classroom-tts-cache/"
  "TTS cache directory."
  :type 'directory)

;; create cache dir
(unless (file-directory-p classroom-tts-cache-dir)
  (make-directory classroom-tts-cache-dir t))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Runtime Variables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar classroom-students nil)

(defvar classroom-current-pool nil)

(defvar classroom-history nil)

(defvar classroom-round 1)

(defvar classroom-last-cancelled-id nil)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Random Seed
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(random t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Score Levels
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst classroom-score-levels
  '(("0" . "无回答")
    ("1" . "回答错误且解释无逻辑")
    ("2" . "回答错误解释有逻辑/回答正确解释无逻辑")
    ("3" . "回答正确解释有逻辑")
    ("4" . "推翻已有结论并提出新观点")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pinyin
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-name-pinyin (name)
  "Convert Chinese NAME to pinyin with tones."
  (with-temp-buffer
    (call-process
     "python3"
     nil
     t
     nil
     "-c"
     "
from pypinyin import lazy_pinyin, Style
import sys

name = sys.argv[1]

result = ' '.join(
    word.capitalize()
    for word in lazy_pinyin(
        name,
        style=Style.TONE
    )
)

print(result)
"
     name)
    (string-trim (buffer-string))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Student Formatting
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-format-student (student)
  "Format STUDENT for big UI."
  (format "%s (%s)\n%s\n%s"
          (plist-get student :name)
          (plist-get student :pinyin)
          (plist-get student :id)
          (plist-get student :group)))

(defun classroom-student-line (student)
  "One line student info."
  (format "%s (%s) [%s] <%s>"
          (plist-get student :name)
          (plist-get student :pinyin)
          (plist-get student :id)
          (plist-get student :group)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CSV Loading
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-load-csv (file)
  "Load students from CSV FILE."
  (interactive "fCSV file: ")
  (setq classroom-students nil)
  (with-temp-buffer
    (insert-file-contents file)
    ;; skip header
    (goto-char (point-min))
    (forward-line 1)
    (while (not (eobp))
      (let* ((line (string-trim
                    (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
             (parts (split-string line "," t "[ \t]+")))
        ;; id,name,group
        (when (>= (length parts) 3)
          (let* ((id (nth 0 parts))
                 (name (nth 1 parts))
                 (group (nth 2 parts))
                 (pinyin (classroom-name-pinyin name)))
            (push `(:id ,id :name ,name :pinyin ,pinyin :group ,group)
                  classroom-students)))
        (forward-line 1)))
    (setq classroom-students (nreverse classroom-students))
    (classroom-reset-pool)
    (message "Loaded %d students" (length classroom-students))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Shuffle
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-shuffle (list)
  "Shuffle LIST."
  (random t)
  (let ((vec (vconcat list)))
    (cl-loop for i from (1- (length vec)) downto 1
             do (cl-rotatef (aref vec i) (aref vec (random (1+ i)))))
    (append vec nil)))

(defun classroom-reset-pool ()
  "Reset pool."
  (setq classroom-current-pool
        (classroom-shuffle classroom-students)))

(defun classroom-next-student ()
  "Get next student."
  ;; next round
  (when (null classroom-current-pool)
    (setq classroom-round (1+ classroom-round))
    (classroom-reset-pool)
    (message "=== 第 %d 轮开始 ===" classroom-round))
  ;; avoid immediate repeat
  (let ((candidate nil)
        (attempts 0))
    (while (and (< attempts 20)
                (or (null candidate)
                    (equal (plist-get candidate :id)
                           classroom-last-cancelled-id)))
      (setq candidate (pop classroom-current-pool))
      ;; same as cancelled
      (when (and candidate
                 (equal (plist-get candidate :id)
                        classroom-last-cancelled-id))
        ;; reshuffle
        (setq classroom-current-pool
              (classroom-shuffle
               (append classroom-current-pool (list candidate))))
        (setq candidate nil))
      (setq attempts (1+ attempts)))
    candidate))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Persistent State
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-save-state ()
  "Save persistent state."
  (with-temp-file classroom-state-file
    (insert ";;; classroom persistent state\n\n")
    (prin1 `(setq classroom-round ',classroom-round) (current-buffer))
    (insert "\n\n")
    (prin1 `(setq classroom-current-pool ',classroom-current-pool) (current-buffer))
    (insert "\n\n")
    (prin1 `(setq classroom-history ',classroom-history) (current-buffer))
    (insert "\n\n")
    (prin1 `(setq classroom-students ',classroom-students) (current-buffer))
    (insert "\n\n")
    (prin1 `(setq classroom-last-cancelled-id ',classroom-last-cancelled-id) (current-buffer))))

(defun classroom-load-state ()
  "Load persistent state."
  (interactive)
  (if (file-exists-p classroom-state-file)
      (progn
        (load-file classroom-state-file)
        (message "课堂状态已恢复"))
    (message "未发现课堂状态文件")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; UI
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-buffer ()
  (get-buffer-create "*Classroom Call*"))

(defun classroom-render (text)
  "Render TEXT."
  (with-current-buffer (classroom-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "\n\n")
      (insert (propertize "课堂提问系统\n\n" 'face '(:height 2.0 :weight bold)))
      (insert (propertize (format "第 %d 轮\n" classroom-round) 'face '(:height 1.5 :weight bold)))
      (insert (format "剩余人数：%d\n" (length classroom-current-pool)))
      (insert (format "已回答人数：%d\n\n" (- (length classroom-students) (length classroom-current-pool))))
      (insert (propertize text 'face '(:height 2.5 :weight bold)))
      (goto-char (point-min))
      (center-region (point-min) (point-max))
      (special-mode)))
  (switch-to-buffer (classroom-buffer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Rolling Animation
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-roll-animation ()
  "Rolling animation."
  (random t)
  (dotimes (i 35)
    (let* ((student (nth (random (length classroom-students)) classroom-students))
           (display (classroom-format-student student)))
      (classroom-render display)
      ;; gradually slower
      (sit-for (+ 0.015 (* i 0.005))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Grade
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-grade-student ()
  "Grade student."
  (let ((choice (read-char-choice
                 "
0 无回答
1 回答错误且解释无逻辑
2 回答错误解释有逻辑/回答正确解释无逻辑
3 回答正确解释有逻辑
4 推翻已有结论并提出新观点
c 取消本次点名

评分: "
                 '(?0 ?1 ?2 ?3 ?4 ?c))))
    (cond ((eq choice ?c) 'cancel)
          (t (assoc-default (char-to-string choice) classroom-score-levels)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Org Record
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-save-record (student grade)
  "Save STUDENT and GRADE."
  (with-current-buffer (find-file-noselect classroom-org-file)
    (goto-char (point-max))
    (insert (format "\n* 第%d轮 %s\n" classroom-round (classroom-student-line student)))
    (insert ":PROPERTIES:\n")
    (insert (format ":ID: %s\n" (plist-get student :id)))
    (insert (format ":NAME: %s\n" (plist-get student :name)))
    (insert (format ":PINYIN: %s\n" (plist-get student :pinyin)))
    (insert (format ":GROUP: %s\n" (plist-get student :group)))
    (insert (format ":GRADE: %s\n" grade))
    (insert (format ":TIME: %s\n" (format-time-string "[%Y-%m-%d %a %H:%M:%S]")))
    (insert ":END:\n\n")
    (save-buffer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; History
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-add-history (student grade)
  "Add history."
  (push (list :id (plist-get student :id)
              :name (plist-get student :name)
              :pinyin (plist-get student :pinyin)
              :group (plist-get student :group)
              :grade grade
              :round classroom-round
              :time (format-time-string "%Y-%m-%d %H:%M:%S"))
        classroom-history))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Statistics
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-grade-distribution ()
  "Grade distribution."
  (let ((table (make-hash-table :test #'equal)))
    ;; init
    (dotimes (i 5) (puthash i 0 table))
    ;; count
    (dolist (x classroom-history)
      (let ((grade (plist-get x :grade)))
        (cond ((string= grade "无回答") (puthash 0 (1+ (gethash 0 table 0)) table))
              ((string= grade "回答错误且解释无逻辑") (puthash 1 (1+ (gethash 1 table 0)) table))
              ((string= grade "回答错误解释有逻辑/回答正确解释无逻辑") (puthash 2 (1+ (gethash 2 table 0)) table))
              ((string= grade "回答正确解释有逻辑") (puthash 3 (1+ (gethash 3 table 0)) table))
              ((string= grade "推翻已有结论并提出新观点") (puthash 4 (1+ (gethash 4 table 0)) table)))))
    table))

(defun classroom-show-statistics ()
  "Show classroom statistics."
  (interactive)
  (let* ((remaining (length classroom-current-pool))
         (answered (- (length classroom-students) remaining))
         (dist (classroom-grade-distribution)))
    (with-current-buffer (get-buffer-create "*Classroom Statistics*")
      (erase-buffer)
      (insert "课堂统计\n\n")
      (insert (format "当前轮次：%d\n\n" classroom-round))
      (insert (format "未回答人数：%d\n" remaining))
      (insert (format "已回答人数：%d\n\n" answered))
      (insert "成绩分布\n\n")
      (dotimes (i 5)
        (insert (format "%d : %s (%d)\n" i (make-string (gethash i dist 0) ?█) (gethash i dist 0))))
      (insert "\n\n未回答学生\n\n")
      (dolist (student classroom-current-pool)
        (insert (classroom-student-line student))
        (insert "\n"))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; TTS (Edge-TTS + Cache)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-tts-file (text)
  "Return TTS cache file path for TEXT."
  (expand-file-name
   (concat (md5 (concat classroom-tts-voice classroom-tts-rate text)) ".mp3")
   classroom-tts-cache-dir))

(defun classroom-generate-tts (text)
  "Generate cached TTS for TEXT, with error reporting."
  (let ((file (classroom-tts-file text)))
    (unless (file-exists-p file)
      (message "Generating TTS: %s" text)
      (let ((ret (call-process "edge-tts" nil (list (get-buffer-create "*TTS-log*") t) nil
                               "--voice" classroom-tts-voice
                               (format "--rate=%s" classroom-tts-rate)
                               "--text" text
                               "--write-media" file)))
        (unless (eq ret 0)
          (error "edge-tts failed with code %d, see *TTS-log*" ret))))
    file))

(defun classroom-play-tts (file)
  "Play TTS FILE."
  (when (file-exists-p file)
    ;; stop previous player
    (ignore-errors
      (call-process "pkill" nil nil nil "-f" "mpv.*classroom-tts-cache"))
    ;; play
    (start-process "classroom-tts-player" nil "mpv" "--really-quiet" file)))

(defun classroom-speak (text)
  "Speak TEXT using cached TTS."
  (when classroom-enable-tts
    (classroom-play-tts (classroom-generate-tts text))))

(defun classroom-precache-tts ()
  "Pre-generate all classroom TTS."
  (interactive)
  (unless classroom-students
    (user-error "No students loaded"))
  (message "开始预生成 TTS 缓存...")
  ;; generic sentences (for grade feedback)
  (dolist (text '("无回答"
                  "回答错误且解释无逻辑"
                  "回答错误解释有逻辑或回答正确解释无逻辑"
                  "回答正确解释有逻辑"
                  "推翻已有结论并提出新观点"))
    (classroom-generate-tts text))
  ;; all students
  (dolist (student classroom-students)
    (let ((name (plist-get student :name)))
      (classroom-generate-tts (format "请 %s 回答问题" name))))
  (message "TTS 缓存预生成完成"))

(defun classroom-preheat-tts ()
  "Background TTS preheat."
  (interactive)
  (run-with-idle-timer 1 nil #'classroom-precache-tts)
  (message "后台开始预热 TTS 缓存"))

(defun classroom-clear-tts-cache ()
  "Clear TTS cache."
  (interactive)
  (when (y-or-n-p "确定清空 TTS 缓存？ ")
    (delete-directory classroom-tts-cache-dir t)
    (make-directory classroom-tts-cache-dir t)
    (message "TTS 缓存已清空")))

(defun classroom-speak-current-student (student)
  "Speak STUDENT name for calling."
  (classroom-speak (format "请 %s 回答问题" (plist-get student :name))))

(defun classroom-speak-grade (student grade)
  "Speak feedback based on GRADE. 直接播报成绩等级描述。"
  (classroom-speak grade))  ; 只播报等级文本，不附加名字

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main Flow (with TTS integration)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-call ()
  "Main call flow."
  (interactive)
  (unless classroom-students
    (if (y-or-n-p "恢复上次课堂状态？ ")
        (classroom-load-state)
      (call-interactively #'classroom-load-csv)))
  ;; rolling animation
  (classroom-roll-animation)
  ;; actual student
  (let* ((student (classroom-next-student))
         (display (classroom-format-student student)))
    ;; reset cancel flag
    (setq classroom-last-cancelled-id nil)
    ;; show
    (classroom-render (format ">>> %s <<<" display))
    ;; speak student name
    (classroom-speak-current-student student)
    ;; grading
    (let ((grade (classroom-grade-student)))
      ;; cancel
      (if (eq grade 'cancel)
          (progn
            (setq classroom-last-cancelled-id (plist-get student :id))
            (setq classroom-current-pool
                  (classroom-shuffle (append classroom-current-pool (list student))))
            (classroom-save-state)
            (message "已取消点名，并重新随机"))
        ;; normal
        (progn
          (classroom-save-record student grade)
          (classroom-add-history student grade)
          (classroom-save-state)
          (classroom-speak-grade student grade)  ; 直接播报成绩描述
          (message "%s -> %s" display grade))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Start
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-start ()
  "Start classroom system."
  (interactive)
  (if (and (file-exists-p classroom-state-file)
           (y-or-n-p "发现课堂状态，是否恢复？ "))
      (classroom-load-state)
    (progn
      (setq classroom-round 1)
      (setq classroom-history nil)
      (setq classroom-last-cancelled-id nil)
      (call-interactively #'classroom-load-csv)
      (classroom-save-state)))
  (delete-other-windows)
  (switch-to-buffer (classroom-buffer))
  (classroom-mode 1)
  (message "课堂系统已启动")
  ;; start TTS cache preheat in background
  (classroom-preheat-tts))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pool Display
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom-show-pool ()
  "Show remaining pool."
  (interactive)
  (with-current-buffer (get-buffer-create "*Classroom Pool*")
    (erase-buffer)
    (insert (format "第 %d 轮剩余学生\n\n" classroom-round))
    (dolist (student classroom-current-pool)
      (insert (classroom-student-line student))
      (insert "\n"))
    (goto-char (point-min))
    (display-buffer (current-buffer))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Keymap
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar classroom-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'classroom-call)
    (define-key map (kbd "s") #'classroom-show-statistics)
    (define-key map (kbd "p") #'classroom-show-pool)
    ;; TTS management
    (define-key map (kbd "t") #'classroom-precache-tts)
    (define-key map (kbd "T") #'classroom-preheat-tts)
    (define-key map (kbd "C") #'classroom-clear-tts-cache)
    map))

(define-minor-mode classroom-mode
  "Classroom mode."
  :lighter " Classroom"
  :keymap classroom-mode-map)

(defun classroom-export-csv (&optional output-file)
  "将 `classroom-record.org` 中的课堂记录导出为 CSV 表格。
列顺序：姓名, 学号, 班级, Round1, Round2, ...
成绩用数字 0-4 表示（0=无回答，1=错无逻辑，2=错有逻辑/对无逻辑，3=对有逻辑，4=新观点）。
如果未提供 OUTPUT-FILE，则导出到桌面 classroom-grades.csv。"
  (interactive (list (read-file-name "导出 CSV 到: " "~/Desktop/" nil nil "classroom-grades.csv")))
  (let* ((org-file (expand-file-name classroom-org-file))
         (records nil)
         (student-ids nil)
         (max-round 0)
         ;; 文字 → 数字映射表（从 classroom-score-levels 生成）
         (grade-to-number
          (let ((ht (make-hash-table :test 'equal)))
            (dolist (pair classroom-score-levels)
              (puthash (cdr pair) (string-to-number (car pair)) ht))
            ht)))
    ;; 1. 解析 Org 文件
    (if (not (file-exists-p org-file))
        (error "记录文件 %s 不存在" org-file)
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
                        (push id student-ids)))))))))))

    ;; 2. 构建学生信息表
    (let ((students-info (make-hash-table :test 'equal)))
      (dolist (r records)
        (puthash (plist-get r :id)
                 (list :name (plist-get r :name) :group (plist-get r :group))
                 students-info))
      (setq student-ids (sort student-ids #'string<))

      ;; 3. 生成 CSV
      (with-temp-buffer
        ;; 表头
        (insert "姓名,学号,班级")
        (dotimes (i max-round)
          (insert (format ",Round%d" (1+ i))))
        (insert "\n")

        ;; 逐行
        (dolist (id student-ids)
          (let* ((info (gethash id students-info))
                 (name (plist-get info :name))
                 (group (plist-get info :group))
                 (grades-by-round (make-hash-table :test 'eql)))
            (dolist (r records)
              (when (equal (plist-get r :id) id)
                (puthash (plist-get r :round) (plist-get r :grade) grades-by-round)))
            (insert (format "%s,%s,%s" name id group))
            (dotimes (i max-round)
              (let ((round-num (1+ i)))
                (insert (format ",%s" (or (gethash round-num grades-by-round) "")))))
            (insert "\n")))

        ;; 4. 写入文件并打开
        (write-region (point-min) (point-max) output-file nil 'silent)
        (message "CSV 已导出到 %s" output-file)
        (find-file output-file)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Provide
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'classroom-call)

;;; classroom-call.el ends here
