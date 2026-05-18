;;; classroom-call.el --- Classroom random call system with TTS  -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'subr-x)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Config
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgroup classroom-call nil
  "Classroom random call system."
  :group 'applications)

(defcustom classroom-directory
  (if load-file-name
      (file-name-directory load-file-name)
    (file-name-directory (or buffer-file-name default-directory)))
  "The directory where classroom-call.el resides.
Used as base path for output files like charts and CSV exports."
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
  '("mpv" "--volume-max=150")
  "Command list to play an audio file.
The file path will be appended to this list.
Example: (\"mpv\" \"--really-quiet\") or (\"ffplay\" \"-nodisp\" \"-autoexit\" \"-loglevel\" \"quiet\")"
  :type '(repeat string)
  :group 'classroom-call)

;; Ensure directories exist
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
  (interactive (list (read-file-name "CSV file: "
                                     (file-name-directory classroom-default-students-file)
                                     nil nil
                                     (file-name-nondirectory classroom-default-students-file))))
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
;; Statistics & Chart
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun classroom--generate-chart (class-data output-file)
  "Generate chart using Python script and CLASS-DATA, save to OUTPUT-FILE."
  (let* ((labels '("无回答" "回答错误且解释无逻辑"
                   "回答错误解释有逻辑/回答正确解释无逻辑"
                   "回答正确解释有逻辑"
                   "推翻已有结论并提出新观点"))
         (classes (mapcar #'car class-data))
         (data (vconcat (mapcar (lambda (c) (vconcat (append (cdr c) nil))) class-data)))
         (json-file (make-temp-file "classroom-data-" nil ".json"))
         (json-str (json-encode `((labels . ,(vconcat labels))
                                  (classes . ,(vconcat classes))
                                  (data . ,data))))
         (err-buf (get-buffer-create "*classroom-chart-debug*"))
         ret)
    (with-temp-file json-file
      (insert json-str))
    (setq ret (call-process "python3" nil (list err-buf t) nil
                            classroom-plot-script
                            json-file
                            output-file))
    (message "Python 脚本 stderr:\n%s" (with-current-buffer err-buf (buffer-string)))
    (delete-file json-file)
    (if (not (eq ret 0))
        (error "图表生成失败，退出码 %d，查看 *classroom-chart-debug* 缓冲区" ret)
      (message "图表已生成: %s" output-file))))

(defun classroom-show-statistics ()
  "Show classroom statistics with per-class grade distribution chart."
  (interactive)
  (let* ((remaining (length classroom-current-pool))
         (answered (- (length classroom-students) remaining))
         (class-dist (make-hash-table :test 'equal))
         classes)
    ;; Aggregate per-class grades
    (dolist (entry classroom-history)
      (let* ((grade (plist-get entry :grade))
             (group (or (plist-get entry :group) "未知班级"))
             (vec (gethash group class-dist)))
        (unless vec
          (setq vec (make-vector 5 0))
          (puthash group vec class-dist)
          (push group classes))
        (let ((idx (cond ((string= grade "无回答") 0)
                         ((string= grade "回答错误且解释无逻辑") 1)
                         ((string= grade "回答错误解释有逻辑/回答正确解释无逻辑") 2)
                         ((string= grade "回答正确解释有逻辑") 3)
                         ((string= grade "推翻已有结论并提出新观点") 4)
                         (t -1))))
          (unless (= idx -1)
            (aset vec idx (1+ (aref vec idx)))))))
    (setq classes (sort classes #'string<))
    (let* ((chart-file classroom-stats-image-file)
           (class-data (mapcar (lambda (c) (cons c (gethash c class-dist))) classes)))
      ;; Generate chart
      (condition-case err
          (classroom--generate-chart class-data chart-file)
        (error (message "无法生成图表：%s" (error-message-string err))
               (setq chart-file nil)))
      ;; Prepare Org buffer
      (with-current-buffer (get-buffer-create "*Classroom Statistics*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (org-mode)
          (insert (format "* 课堂统计（第 %d 轮）\n\n" classroom-round))
          (insert (format "- 未回答人数：%d\n" remaining))
          (insert (format "- 已回答人数：%d\n\n" answered))
          (if (and chart-file (file-exists-p chart-file))
              (insert "** 成绩分布图\n\n"
                      (format "[[file:%s]]\n\n" chart-file))
            (insert "** 成绩分布（图表生成失败）\n\n"))
          (insert "** 无回答学生\n\n")
          (let ((no-answer-students (make-hash-table :test 'equal)))
            (dolist (entry classroom-history)
              (when (string= (plist-get entry :grade) "无回答")
                (let ((id (plist-get entry :id))
                      (name (plist-get entry :name))
                      (group (plist-get entry :group))
                      (pinyin (plist-get entry :pinyin)))
                  (unless (gethash id no-answer-students)
                    (puthash id (format "%s (%s) [%s] <%s>" name pinyin id group) no-answer-students)))))
            (if (hash-table-empty-p no-answer-students)
                (insert "无\n")
              (maphash (lambda (_id line)
                         (insert "- " line "\n"))
                       no-answer-students)))
          (goto-char (point-min))))
      (pop-to-buffer "*Classroom Statistics*")
      ;; Display inline image after buffer is ready
      (when (and chart-file (file-exists-p chart-file))
        (run-with-idle-timer 0.1 nil
                             (lambda ()
                               (with-current-buffer "*Classroom Statistics*"
                                 (org-display-inline-images t t))))))))

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
  "Play TTS FILE using customizable player command."
  (when (file-exists-p file)
    ;; Stop any previous player (optional, can be customized per player)
    (ignore-errors
      (kill-process "classroom-tts-player"))
    ;; Start new player
    (apply #'start-process
           "classroom-tts-player"
           nil
           (append classroom-tts-player-command (list file)))))

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
  ;; generic grade sentences
  (dolist (text '("无回答"
                  "回答错误且解释无逻辑"
                  "回答错误解释有逻辑或回答正确解释无逻辑"
                  "回答正确解释有逻辑"
                  "推翻已有结论并提出新观点"))
    (classroom-generate-tts text))
  ;; each student call sentence
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

(defun classroom-speak-grade (_student grade)
  "Speak GRADE text only (without student name)."
  (classroom-speak grade))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main Flow
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
    (setq classroom-last-cancelled-id nil)
    (classroom-render (format ">>> %s <<<" display))
    (classroom-speak-current-student student)
    (let ((grade (classroom-grade-student)))
      (if (eq grade 'cancel)
          (progn
            (setq classroom-last-cancelled-id (plist-get student :id))
            (setq classroom-current-pool
                  (classroom-shuffle (append classroom-current-pool (list student))))
            (classroom-save-state)
            (message "已取消点名，并重新随机"))
        (progn
          (classroom-save-record student grade)
          (classroom-add-history student grade)
          (classroom-save-state)
          (classroom-speak-grade student grade)
          (message "%s -> %s" display grade))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Start / Resume
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
    ;; Parse Org
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
    ;; Build output
    (let ((students-info (make-hash-table :test 'equal)))
      (dolist (r records)
        (puthash (plist-get r :id)
                 (list :name (plist-get r :name) :group (plist-get r :group))
                 students-info))
      (setq student-ids (sort student-ids #'string<))
      (with-temp-buffer
        (insert "姓名,学号,班级")
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
            (insert (format "%s,%s,%s" name id group))
            (dotimes (i max-round)
              (let ((round-num (1+ i)))
                (insert (format ",%s" (or (gethash round-num grades-by-round) "")))))
            (insert "\n")))
        (write-region (point-min) (point-max) output-file nil 'silent)
        (message "CSV 已导出到 %s" output-file)
        (find-file output-file)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Provide
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'classroom-call)
;;; classroom-call.el ends here
