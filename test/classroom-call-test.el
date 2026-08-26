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
  (setq classroom-students '((:id "1" :name "A") (:id "2" :name "B")))
  (setq classroom-current-pool nil)
  (setq classroom-round 1)
  (let ((next (classroom-next-student)))
    (should next)
    (should (= classroom-round 2))))

(ert-deftest classroom-reset-pool-keeps-no-answer-counts ()
  (setq classroom-students '((:id "1" :name "A") (:id "2" :name "B")))
  (setq classroom-no-answer-counts '(("1" . 2)))
  (classroom-reset-pool)
  (should (equal (alist-get "1" classroom-no-answer-counts nil nil #'equal) 2)))

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
                classroom-no-answer-counts '(("8" . 2))
                classroom-unanswered-pool '((:id "9" :name "I")))
          (classroom-save-state)
          (setq classroom-round 1
                classroom-current-pool nil
                classroom-history nil
                classroom-students nil
                classroom-last-cancelled-id nil
                classroom-no-answer-counts nil
                classroom-unanswered-pool nil)
          (classroom-load-state)
          (should (= classroom-round 3))
          (should (= (length classroom-current-pool) 2)) ; pool + merged
          (should (equal classroom-history '((:id "8" :name "H" :grade "无回答"))))
          (should (equal classroom-last-cancelled-id "8"))
          (should (equal classroom-no-answer-counts '(("8" . 2))))
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
                classroom-no-answer-counts nil
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
;; No-answer accounting
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(ert-deftest classroom-clear-no-answer ()
  (setq classroom-no-answer-counts '(("1" . 2) ("2" . 1)))
  (classroom--clear-no-answer "1")
  (should (equal classroom-no-answer-counts '(("2" . 1))))
  (classroom--clear-no-answer "2")
  (should (null classroom-no-answer-counts)))

(ert-deftest classroom-hang-student-postpones-without-strike ()
  (let ((org (make-temp-file "classroom-record-" nil ".org"))
        (state (make-temp-file "classroom-state-" nil ".el")))
    (unwind-protect
        (progn
          (setq classroom-org-file org
                classroom-state-file state
                classroom-students '((:id "1" :name "A" :pinyin "A" :group "1班")
                                     (:id "2" :name "B" :pinyin "B" :group "1班"))
                classroom-no-answer-counts '(("2" . 1))
                classroom-unanswered-pool nil
                classroom-history nil
                classroom-round 1)
          (classroom--hang-student (car classroom-students))
          ;; postponed to the next session
          (should (= (length classroom-unanswered-pool) 1))
          (should (equal (plist-get (car classroom-unanswered-pool) :id) "1"))
          ;; no-answer counts are untouched by 挂起
          (should (equal (alist-get "2" classroom-no-answer-counts nil nil #'equal) 1))
          (should (null (alist-get "1" classroom-no-answer-counts nil nil #'equal)))
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

(provide 'classroom-call-test)
;;; classroom-call-test.el ends here
