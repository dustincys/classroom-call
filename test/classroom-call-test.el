;;; classroom-call-test.el --- ERT tests for classroom-call  -*- lexical-binding: t; -*-
;; Copyright (c) 2026
;; Author: YanshuoChu
;; License: GPL-3.0

;; Run with:
;;   emacs -Q --batch -L . -l test/classroom-call-test.el \
;;         --eval '(ert-run-tests-batch-and-exit)'

;;; Commentary:

;; Unit tests covering shuffle, cancel avoidance, persistent state,
;; rubric helpers, CSV parsing/escaping and no-answer accounting.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../classroom-call.el"
                            (file-name-directory (or load-file-name buffer-file-name))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Shuffle
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-shuffle-preserves-elements ()
  (let* ((students '((:id "1") (:id "2") (:id "3") (:id "4") (:id "5")))
         (shuffled (classroom-shuffle students)))
    (should (= (length shuffled) (length students)))
    (should (equal (sort (mapcar (lambda (s) (plist-get s :id)) shuffled) #'string<)
                   (sort (mapcar (lambda (s) (plist-get s :id)) students) #'string<)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Next student / cancel avoidance
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-next-student-avoids-cancelled ()
  (setq classroom-students
        '((:id "1" :name "A") (:id "2" :name "B") (:id "3" :name "C")))
  (setq classroom-current-pool
        '((:id "1" :name "A") (:id "2" :name "B") (:id "3" :name "C")))
  (setq classroom-last-cancelled-id "1")
  (let ((next (classroom-next-student)))
    (should next)
    (should-not (equal (plist-get next :id) "1"))))

(ert-deftest classroom-next-student-only-cancelled-remaining ()
  ;; When the only remaining student is the cancelled one, we must
  ;; still return it (no infinite loop, no nil).
  (setq classroom-students '((:id "1" :name "A")))
  (setq classroom-current-pool '((:id "1" :name "A")))
  (setq classroom-last-cancelled-id "1")
  (let ((next (classroom-next-student)))
    (should next)
    (should (equal (plist-get next :id) "1"))))

(ert-deftest classroom-next-student-new-round ()
  (setq classroom-students '((:id "1" :name "A") (:id "2" :name "B"))
        classroom-current-pool nil
        classroom-unanswered-pool nil
        classroom-last-cancelled-id nil
        classroom-round 1)
  (let ((next (classroom-next-student)))
    (should next)
    (should (= classroom-round 2))))

(ert-deftest classroom-reset-pool-excludes-postponed ()
  ;; Postponed (挂起) students must NOT re-enter the draw pool when a new
  ;; round starts within the same session; they only come back via
  ;; `classroom-load-state' on the next session.
  (setq classroom-students '((:id "1" :name "A") (:id "2" :name "B") (:id "3" :name "C"))
        classroom-unanswered-pool '((:id "2" :name "B"))
        classroom-current-pool nil)
  (classroom-reset-pool)
  (should (= (length classroom-current-pool) 2))
  (should (cl-every (lambda (s) (not (equal (plist-get s :id) "2")))
                    classroom-current-pool)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Persistent state
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-state-round-trip ()
  (let ((state-file (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (setq classroom-state-file state-file
                classroom-round 3
                classroom-current-pool '((:id "8" :name "H"))
                classroom-history '((:id "8" :name "H" :grade "无回答"))
                classroom-students '((:id "8" :name "H" :group "1班"))
                classroom-last-cancelled-id "8"
                classroom-unanswered-pool '((:id "9" :name "I")))
          (classroom-save-state)
          (setq classroom-round 1
                classroom-current-pool nil
                classroom-history nil
                classroom-students nil
                classroom-last-cancelled-id nil
                classroom-unanswered-pool nil)
          (classroom-load-state)
          (should (= classroom-round 3))
          (should (= (length classroom-current-pool) 2)) ; pool + merged
          (should (equal classroom-history '((:id "8" :name "H" :grade "无回答"))))
          (should (equal classroom-last-cancelled-id "8"))
          ;; The unanswered pool was merged and the merge persisted.
          (should (null classroom-unanswered-pool))
          (let ((saved (classroom--read-state-data)))
            (should (null (plist-get saved :unanswered-pool)))
            (should (= (length (plist-get saved :pool)) 2))))
      (delete-file state-file))))

(ert-deftest classroom-state-file-is-data-not-code ()
  ;; The state file must not contain executable `setq' forms.
  (let ((state-file (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (setq classroom-state-file state-file
                classroom-round 7
                classroom-current-pool nil
                classroom-history nil
                classroom-students nil
                classroom-last-cancelled-id nil
                classroom-unanswered-pool nil)
          (classroom-save-state)
          (with-temp-buffer
            (insert-file-contents state-file)
            (goto-char (point-min))
            (let ((form (read (current-buffer))))
              (should (eq (car form) 'classroom--state-data))
              (should (equal (plist-get (nth 1 form) :round) 7)))))
      (delete-file state-file))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Rubric helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-score-level-helpers ()
  (should (string= (classroom-score-level-label "0") "无回答"))
  (should (string= (classroom-score-level-key "无回答") "0"))
  (should (string= (classroom-score-level-label "99") "99"))
  (should (null (classroom-score-level-key "不存在的等级")))
  (should (= (length (classroom-score-level-labels)) 5)))

(ert-deftest classroom-score-level-points ()
  (should (= (classroom-score-level-points "0") 0))
  (should (= (classroom-score-level-points "1") 60))
  (should (= (classroom-score-level-points "2") 80))
  (should (= (classroom-score-level-points "3") 98))
  (should (= (classroom-score-level-points "4") 100))
  (should (null (classroom-score-level-points "9"))))

(ert-deftest classroom-grade-prompt-order-and-scores ()
  (let ((prompt (classroom--grade-prompt)))
    ;; 10+ line menu: header, best level first, worst last, then
    ;; 无回答 / 挂起 / 取消.
    (should (>= (length (split-string prompt "\n")) 11))
    (should (string-match-p "\\`=== 评分选项 ===" prompt))
    (should (string-match-p "（100分）" prompt))
    (should (string-match-p "（98分）" prompt))
    (should (string-match-p "（80分）" prompt))
    (should (string-match-p "（60分）" prompt))
    (should (string-match-p "（0分）" prompt))
    (should (< (string-match "4 " prompt)
               (string-match "3 " prompt)
               (string-match "2 " prompt)
               (string-match "1 " prompt)
               (string-match "0 " prompt)
               (string-match "a 挂起" prompt)
               (string-match "c 取消" prompt)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CSV parsing / escaping
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-split-csv-line-quoted ()
  (should (equal (classroom--split-csv-line "1,张三,1班")
                 '("1" "张三" "1班")))
  (should (equal (classroom--split-csv-line "1,\"张,三\",1班")
                 '("1" "张,三" "1班")))
  (should (equal (classroom--split-csv-line "1,\"a\"\"b\",1班")
                 '("1" "a\"b" "1班"))))

(ert-deftest classroom-csv-escape ()
  (should (string= (classroom--csv-escape "张三") "张三"))
  (should (string= (classroom--csv-escape "张,三") "\"张,三\""))
  (should (string= (classroom--csv-escape "a\"b") "\"a\"\"b\"")))

(ert-deftest classroom-load-csv-basic ()
  (let ((csv (make-temp-file "students-" nil ".csv"))
        (state-file (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file csv
            (insert "id,name,group\n20230001,张三,1班\n20230002,李四,2班\n"))
          (setq classroom-state-file state-file)
          (classroom-load-csv csv)
          (should (= (length classroom-students) 2))
          (should (string= (plist-get (car classroom-students) :id) "20230001"))
          (should (string= (plist-get (car classroom-students) :name) "张三"))
          (should (string= (plist-get (car classroom-students) :group) "1班"))
          ;; pinyin falls back to the name when pypinyin is unavailable,
          ;; and is a string either way.
          (should (stringp (plist-get (car classroom-students) :pinyin))))
      (delete-file csv)
      (delete-file state-file))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Hang (absent) handling
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-hang-student-postpones ()
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (state (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (setq classroom-org-file org
                classroom-state-file state
                classroom-students '((:id "1" :name "A" :pinyin "A" :group "1班")
                                     (:id "2" :name "B" :pinyin "B" :group "1班"))
                classroom-unanswered-pool nil
                classroom-history nil
                classroom-round 1)
          (classroom--hang-student (car classroom-students))
          ;; postponed to the next session
          (should (= (length classroom-unanswered-pool) 1))
          (should (equal (plist-get (car classroom-unanswered-pool) :id) "1"))
          ;; recorded in history with the 挂起 grade
          (should (equal (plist-get (car classroom-history) :grade) "挂起"))
          ;; recorded in the org file
          (should (string-match-p "挂起"
                                  (with-temp-buffer
                                    (insert-file-contents org)
                                    (buffer-string)))))
      (delete-file org)
      (delete-file state))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Pinyin passthrough
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-pinyin-ascii-passthrough ()
  (should (classroom--ascii-name-p "James Anderson"))
  (should-not (classroom--ascii-name-p "张三"))
  (should (string= (classroom-name-pinyin "James Anderson") "James Anderson")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Volunteer answer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-student-answered-this-round-p ()
  (setq classroom-round 2
        classroom-history
        (list (list :id "1" :round 2 :grade (classroom-score-level-label "3"))
              (list :id "2" :round 2 :grade "挂起")
              (list :id "1" :round 1 :grade (classroom-score-level-label "0"))))
  (should (classroom--student-answered-this-round-p "1"))
  ;; 挂起 (postponed) has no numeric grade, so it does not count.
  (should-not (classroom--student-answered-this-round-p "2"))
  (should-not (classroom--student-answered-this-round-p "3")))

(ert-deftest classroom-record-volunteer-marks-answered ()
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (state (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (setq classroom-org-file org
                classroom-state-file state
                classroom-enable-tts nil
                classroom-students '((:id "1" :name "A" :pinyin "A" :group "1班")
                                     (:id "2" :name "B" :pinyin "B" :group "1班"))
                classroom-current-pool (copy-tree classroom-students)
                classroom-history nil
                classroom-unanswered-pool nil
                classroom-round 1)
          (classroom--record-volunteer (car classroom-students)
                                       (classroom-score-level-label "4"))
          ;; removed from the draw pool (marked as answered)
          (should (= (length classroom-current-pool) 1))
          (should (equal (plist-get (car classroom-current-pool) :id) "2"))
          ;; recorded in history
          (should (= (length classroom-history) 1))
          (should (equal (plist-get (car classroom-history) :grade)
                         (classroom-score-level-label "4"))))
      (delete-file org)
      (delete-file state))))

(ert-deftest classroom-export-csv-takes-max-per-round ()
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (csv (make-temp-file "classroom-grades-" nil ".csv"))
        (student '(:id "1" :name "A" :pinyin "A" :group "1班")))
    (unwind-protect
        (progn
          (setq classroom-org-file org
                classroom-round 1)
          (classroom-save-record student (classroom-score-level-label "3"))
          (classroom-save-record student (classroom-score-level-label "1"))
          (classroom-export-csv csv)
          (with-temp-buffer
            (insert-file-contents csv)
            (goto-char (point-min))
            (forward-line 1)                  ; skip the header row
            (let ((line (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))))
              ;; A,1,1班,<max grade>
              (should (string-match-p ",3$" line))
              (should-not (string-match-p ",1$" line)))))
      (ignore-errors (delete-file org))
      (ignore-errors (delete-file csv)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Re-grade last answer
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-regrade-last-cancel-multi-answer ()
  ;; Cancelling a re-grade of a second answer must NOT put the student
  ;; back into the draw pool when they still have another answer this
  ;; round.
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (state (make-temp-file "classroom-state-" nil ".el"))
        (student '(:id "1" :name "A" :pinyin "A" :group "1班")))
    (unwind-protect
        (progn
          (with-temp-file org
            (insert "\n* 第1轮 A (A) [1] <1班>\n"
                    ":PROPERTIES:\n:ID: 1\n:NAME: A\n:PINYIN: A\n:GROUP: 1班\n"
                    ":GRADE: 回答正确解释有逻辑，或回答错误但解释很有逻辑\n"
                    ":TIME: [2026-09-01 Tue 15:54:09]\n:END:\n\n")
            (insert "\n* 第1轮 A (A) [1] <1班>\n"
                    ":PROPERTIES:\n:ID: 1\n:NAME: A\n:PINYIN: A\n:GROUP: 1班\n"
                    ":GRADE: 回答正确，但无解释或解释无逻辑\n"
                    ":TIME: [2026-09-01 Tue 16:00:00]\n:END:\n\n"))
          (setq classroom-org-file org
                classroom-state-file state
                classroom-enable-tts nil
                classroom-round 1
                classroom-students (list student)
                classroom-current-pool nil
                classroom-unanswered-pool nil
                classroom-history
                (list (list :id "1" :name "A" :pinyin "A" :group "1班"
                            :grade (classroom-score-level-label "2")
                            :round 1 :time "2026-09-01 16:00:00")
                      (list :id "1" :name "A" :pinyin "A" :group "1班"
                            :grade (classroom-score-level-label "3")
                            :round 1 :time "2026-09-01 15:54:09")))
          (cl-letf (((symbol-function 'classroom-grade-student) (lambda () 'cancel)))
            (classroom-regrade-last))
          (should (= (length classroom-history) 1))
          (should (= (length classroom-current-pool) 0)) ; still answered
          (should (null classroom-unanswered-pool)))
      (ignore-errors (delete-file org))
      (ignore-errors (delete-file state)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; State recovery from the Org record + roster CSV
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-recover-state-rebuilds ()
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (csv (make-temp-file "students-" nil ".csv"))
        (state (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file csv
            (insert "id,name,group\n1,Alice,1班\n2,Bob,1班\n3,Carol,2班\n"))
          (with-temp-file org
            (insert "\n* 第1轮 Alice (Alice) [1] <1班>\n"
                    ":PROPERTIES:\n:ID: 1\n:NAME: Alice\n:PINYIN: Alice\n:GROUP: 1班\n"
                    ":GRADE: 回答正确解释有逻辑，或回答错误但解释很有逻辑\n"
                    ":TIME: [2026-09-01 Tue 15:54:09]\n:END:\n\n")
            (insert "\n* 第1轮 Bob (Bob) [2] <1班>\n"
                    ":PROPERTIES:\n:ID: 2\n:NAME: Bob\n:PINYIN: Bob\n:GROUP: 1班\n"
                    ":GRADE: 挂起\n"
                    ":TIME: [2026-09-01 Tue 16:00:00]\n:END:\n\n"))
          (setq classroom-org-file org
                classroom-default-students-file csv
                classroom-state-file state
                classroom-enable-tts nil)
          (classroom-recover-state)
          (should (= classroom-round 1))
          (should (= (length classroom-students) 3))
          ;; newest first: Bob (挂起) then Alice (graded)
          (should (= (length classroom-history) 2))
          (should (equal (plist-get (car classroom-history) :id) "2"))
          ;; Bob's latest record is 挂起 -> postponed
          (should (= (length classroom-unanswered-pool) 1))
          (should (equal (plist-get (car classroom-unanswered-pool) :id) "2"))
          ;; Carol has no record -> in the pool
          (should (= (length classroom-current-pool) 1))
          (should (equal (plist-get (car classroom-current-pool) :id) "3")))
      (ignore-errors (delete-file org))
      (ignore-errors (delete-file csv))
      (ignore-errors (delete-file state)))))

(provide 'classroom-call-test)
;;; classroom-call-test.el ends here
