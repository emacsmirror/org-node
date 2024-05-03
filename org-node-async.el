;;; org-node-async.el --- The beating heart -*- lexical-binding: t; -*-

(require 'bytecomp)
(require 'org-node-common)
(require 'org-node-worker)

(defvar org-node-async--start-time nil)

(defun org-node-async--split-into-n-sublists (big-list n)
  (let ((len (/ (length big-list) n))
        res)
    (dotimes (i n)
      (push
       (if (= i (- n 1))
           ;; Let the last iteration just take what's left
           big-list
         (prog1 (take len big-list)
           (setq big-list (nthcdr len big-list))))
       res))
    res))

;; (org-node-async--split-into-n-sublists
;;       '(a v e e  q l fk k k ki i o r r  r r r r r r r r g g g  g g gg)
;;       4)

;; (defun org-node-async--stderr-sentinel (stderr-process event)
;;   (with-current-buffer (process-buffer stderr-process)
;;     (if (equal event "finished\n")
;;         (if (= 0 (buffer-size))
;;             nil
;;           (error "%s" (buffer-string)))
;;       (error "%s" (buffer-string)))))

;; ;; Need our own stderr handler for an easy way to see if there was an
;; ;; error.  The default `internal-default-process-sentinel' adds
;; ;; "finished" messages in the stderr buffer, so it is not possible to
;; ;; simply check for a non-empty stderr buffer.
;; ;; https://emacs.stackexchange.com/questions/71492/
;; (defvar org-node-async--stderr-process
;;   (make-pipe-process :name "org-node stderr"
;;                      :buffer "*org-node-async*"
;;                      :noquery t
;;                      :sentinel #'org-node-async--stderr-sentinel))

(defun org-node-async--collect (files)
  (mkdir "/tmp/org-node/" t)
  (with-current-buffer (get-buffer-create "*org-node*")
    (erase-buffer))
  (setq org-node-async--jobs
        (max 1 (1- (string-to-number
                    (pcase system-type
                      ((or 'gnu 'gnu/linux 'gnu/kfreebsd 'berkeley-unix)
                       (if (executable-find "nproc")
                           (shell-command-to-string
                            "nproc --all")
                         (shell-command-to-string
                          "lscpu -p | egrep -v '^#' | wc -l")))
                      ((or 'darwin)
                       (shell-command-to-string
                        "sysctl -n hw.logicalcpu_max"))
                      ((or 'cygwin 'windows-nt 'ms-dos)
                       (user-error "org-node: Windows not supported with `org-node-perf-multicore'")))))))
  (let* ((lib (find-library-name "org-node-worker"))
         (native (when (and (featurep 'native-compile)
                            (native-comp-available-p))
                   (comp-el-to-eln-filename lib)))
         (elc "/tmp/org-node/worker.elc"))
    ;; Pre-compile code for the external Emacs processes,
    ;; in case the user's package manager didn't compile.
    (if native
        (unless (and (file-exists-p native)
                     (file-newer-than-file-p native lib))
          (native-compile lib))
      (unless (and (file-exists-p elc)
                   (file-newer-than-file-p elc lib))
        (let ((byte-compile-dest-file-function
               `(lambda (&rest _) ,elc)))
          (byte-compile-file lib))))

    (setq org-node-async--start-time (current-time))
    (setq org-node-async--done-ctr 0)
    (with-temp-file "/tmp/org-node/work-variables.eld"
      (insert (prin1-to-string (append (org-node--work-variables)
                                       org-node-async-inject-variables))))
    ;; Split the work over many Emacs processes
    (let ((file-lists (org-node-async--split-into-n-sublists
                       files org-node-async--jobs))
          ;; Perf attempts
          ;; (write-region-inhibit-fsync t)
          ;; (coding-system-for-write org-node-perf-assume-coding-system)
          ;; (write-file-hooks nil)
          ;; (file-name-handler-alist nil)

          )
      (while-let ((old-process (pop org-node-async--processes)))
        ;; TODO Keep them alive... but then we have to do actual IPC
        (when (process-live-p old-process)
          (delete-process old-process)))
      (dotimes (i org-node-async--jobs)
        (with-temp-file (format "/tmp/org-node/file-list-%d.eld" i)
          (insert (prin1-to-string (pop file-lists))))
        (push (make-process
               :name (format "org-node-%d" i)
               :noquery t
               :stderr (get-buffer-create "*org-node*")
               :command (list (file-truename
                               (expand-file-name invocation-name
                                                 invocation-directory))
                              "--quick"
                              "--no-init-file"
                              "--no-site-lisp"
                              "--batch"
                              "--insert"
                              (format "/tmp/org-node/file-list-%d.eld" i)
                              "--eval"
                              (format
                               "(setq files (cons %d (car (read-from-string (buffer-string)))))"
                               i)
                              "--load"
                              (or native elc)
                              "--funcall"
                              "org-node-worker--collect")
               :sentinel (lambda (process event)
                           (org-node-async--handle-finished-job
                            process event i)))
              org-node-async--processes)))))

(defvar org-node-async--processes (list))
(defvar org-node-async--done-ctr 0)
(defvar org-node-async--jobs nil)

(defun org-node-async--handle-finished-job (process _ i)
  ;; if-let ((err (or (eq 'signal (process-status process))
  ;;                  (with-current-buffer (process-buffer process)
  ;;                    (flush-lines "finished$")
  ;;                    (flush-lines "^$")
  ;;                    (let ((buffer-string (buffer-string)))
  ;;                      (unless (string-blank-p buffer-string)
  ;;                        buffer-string))))))
  ;; (message "An org-node worker failed to scan files: %s" err)
  (with-temp-buffer
    ;; Paste what the worker output
    (let ((file (format "/tmp/org-node/result-%d.eld" i)))
      (if (not (file-exists-p file))
          (message "An org-node worker failed to scan files, not producing %s"
                   file)
        (insert-file-contents file)
        (delete-file file)
        ;; Execute the demands that the worker wrote
        (let ((please-update-id-locations nil))
          (dolist (demand (car (read-from-string (buffer-string))))
            (apply (car demand) (cdr demand))
            (when (eq 'org-node--forget-id-location (car demand))
              (setq please-update-id-locations t)))
          ;; The last process has completed
          (when (eq (cl-incf org-node-async--done-ctr) org-node-async--jobs)
            (when please-update-id-locations
              (setq please-update-id-locations nil)
              (org-id-update-id-locations)
              (org-id-locations-save)
              ;; in case
              (when (listp org-id-locations)
                (setq org-id-locations (org-id-alist-to-hash org-id-locations))))
            (message "Finished in %.2f s"
                     (float-time (time-since org-node-async--start-time)))))))))

(provide 'org-node-async)

;;; org-node-async.el ends here
