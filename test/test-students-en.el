;;; test-students-en.el --- 5 test students with English names

;; Load with: (load-file "test/test-students-en.el")
;; Or load CSV with: (classroom-load-csv "test/students-en.csv")

(setq classroom-students
      '(
        (:id "20250001" :name "James Anderson" :pinyin "James Anderson" :group "1班")
        (:id "20250002" :name "Emma Williams" :pinyin "Emma Williams" :group "1班")
        (:id "20250003" :name "Michael Chen" :pinyin "Michael Chen" :group "2班")
        (:id "20250004" :name "Sophia Martinez" :pinyin "Sophia Martinez" :group "2班")
        (:id "20250005" :name "Daniel Thompson" :pinyin "Daniel Thompson" :group "3班")))

;; Reset the pool so the students are ready to use
(classroom-reset-pool)
(message "Loaded %d test students (English names)" (length classroom-students))

(provide 'test-students-en)
;;; test-students-en.el ends here
