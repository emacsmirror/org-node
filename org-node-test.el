;;; org-node-test.el -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Martin Edström

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

(require 'ert)
(require 'dash)
(require 'org-node)
(require 'org-node-worker)
(require 'org-node-backlink)
;; (require 'org-node-fakeroam)


;; (-all-p #'org-node-link-p (apply #'append (hash-table-values org-node--dest<>links)))

(ert-deftest org-node-test--split-refs-field ()
  (setq org-node-worker--result:paths-types nil)
  (let ((result
         (org-node-worker--split-refs-field
          (concat "[cite:@citeKey abcd ; @citeKey2 cdefgh;@citeKey3] @foo "
                  " [[https://gnu.org/A Link With Spaces/index.htm][baz]]"
                  " https://gnu.org [citep:&citeKey4]"
                  " info:with%20escaped%20spaces"))))
    (should (--all-p (member it result)
                     '("citeKey2"
                       "citeKey"
                       "citeKey3"
                       "foo"
                       "citeKey4"
                       "with escaped spaces"
                       "//gnu.org/A Link With Spaces/index.htm"
                       "//gnu.org")))
    (should (equal "https" (cdr (assoc "//gnu.org/A Link With Spaces/index.htm"
                                       org-node-worker--result:paths-types))))
    (should (equal "https" (cdr (assoc "//gnu.org"
                                       org-node-worker--result:paths-types))))
    (should (equal nil (cdr (assoc "citeKey"
                                   org-node-worker--result:paths-types))))))

(ert-deftest org-node-test--oldata-fns ()
  (let ((olp '((3730 "A subheading" 2 "33dd")
               (2503 "A top heading" 1 "d3rh")
               (1300 "A sub-subheading" 3 "d3csae")
               (1001 "A subheading" 2 "d3")
               (199 "Another top heading" 1)
               (123 "First heading in file is apparently third-level" 3))))
    (should (equal (org-node-worker--pos->olp olp 1300)
                   '("Another top heading" "A subheading")))
    (should (equal (org-node-worker--pos->olp olp 2503)
                   nil))
    (should-error (org-node-worker--pos->olp olp 2500))
    (should (equal (org-node-worker--pos->parent-id olp 1300 nil)
                   "d3"))))

(ert-deftest org-node-test--parsing-testfile2.org ()
  (org-node--scan-targeted (list "testfile2.org"))
  (org-node-cache-ensure t)
  (let ((node (gethash "bb02315f-f329-4566-805e-1bf17e6d892d" org-node--id<>node)))
    (should (equal (org-node-get-olp node) nil))
    (should (equal (org-node-get-file-title node) "Title"))
    (should (equal (org-node-get-todo node) "CUSTOMDONE"))
    (should (equal (org-node-get-scheduled node) "<2024-06-17 Mon>")))
  (let ((node (gethash "d28cf9b9-d546-46b0-8615-9880a4d2463d" org-node--id<>node)))
    (should (equal (org-node-get-olp node) '("1st-level" "TODO 2nd-level, invalid todo state")))
    (should (equal (org-node-get-title node) "3rd-level, has ID"))
    (should (equal (org-node-get-todo node) nil))))

(ert-deftest org-node-test--having-multiple-id-dirs ()
  (mkdir "/tmp/org-node/test1" t)
  (mkdir "/tmp/org-node/test2" t)
  (write-region "" nil "/tmp/org-node/test2/emptyfile.org")
  (write-region "" nil "/tmp/org-node/test2/emptyfile2.org")
  (write-region "" nil "/tmp/org-node/test1/emptyfile3.org")
  (let ((org-id-locations (make-hash-table :test #'equal))
        (org-node-extra-id-dirs '("/tmp/org-node/test1/"
                                  "/tmp/org-node/test2/"))
        (org-node-ask-directory nil))
    (should (equal (car (org-node--root-dirs (org-node-files)))
                   "/tmp/org-node/test2/"))))

(ert-deftest org-node-test--goto-random ()
  (require 'seq)
  (org-node--scan-targeted (list "testfile2.org"))
  (org-node-cache-ensure t)
  (let ((node (seq-random-elt (hash-table-values org-node--id<>node))))
    (org-node--goto node)
    (should (equal (point) (org-node-get-pos node)))
    (should (equal (abbreviate-file-name (buffer-file-name))
                   (org-node-get-file-path node)))))

(ert-deftest org-node-test--split-into-n-sublists ()
  (should (equal 4 (length (org-node--split-into-n-sublists
                            '(a v e e) 7))))
  (should (equal 1 (length (org-node--split-into-n-sublists
                            '(a v e e) 1))))
  (should (equal 4 (length (org-node--split-into-n-sublists
                            '(a v e e q l fk k k ki i o r r r r r r  r g g gg)
                            4)))))

(ert-deftest org-node-test--file-naming ()
  (let ((org-node-filename-fn #'org-node-slugify-for-web))
    (should (equal (org-node--name-file "19 Foo bar Baz 588")
                   "19-foo-bar-baz-588.org")))
  (let ((org-node-filename-fn nil)
        (org-node-datestamp-format "")
        (org-node-slug-fn #'org-node-slugify-for-web))
    (should (equal (org-node--name-file "19 Foo bar Baz 588")
                   "19-foo-bar-baz-588.org"))
    (should (equal (funcall org-node-slug-fn "19 Foo bar Baz 588")
                   "19-foo-bar-baz-588")))
  (should (equal (org-node--time-format-to-regexp "%Y%M%d")
                 "^[[:digit:]]+"))
  (should (equal (org-node--time-format-to-regexp "%A%Y%M%d-")
                 "^[[:alpha:]]+[[:digit:]]+-")))

(ert-deftest org-node-test--various ()
  (let ((org-node-ask-directory "/tmp/org-node/test/")
        ;; NOTE you should manually test the other creation-fns
        (org-node-creation-fn #'org-node-new-file))
    (delete-directory org-node-ask-directory t)
    ;; (should-error (org-node--create "New node" "not-an-uuid1234"))
    (mkdir org-node-ask-directory t)
    (org-node--create "New node" "not-an-uuid1234")
    (org-node-cache-ensure t)
    (let ((node (gethash "not-an-uuid1234" org-node--id<>node)))
      (org-node--goto node)
      (should (file-equal-p default-directory org-node-ask-directory))
      (should (equal (org-node-get-id node) (org-entry-get nil "ID" t)))
      (should (equal (org-node-get-id node) "not-an-uuid1234"))
      (should (equal (org-node-get-title node) "New node"))
      (should (equal (org-node-get-file-title node) "New node"))
      (should (equal (org-node-get-file-title-or-basename node) "New node")))
    (let ((org-node-prefer-file-level-nodes nil))
      (org-node--create "A top-level heading" "not-an-uuid5678")
      (org-node-cache-ensure t)
      (let ((node (gethash "not-an-uuid5678" org-node--id<>node))
            (expected-filename (funcall org-node-filename-fn "A top-level heading")))
        (should (equal (org-node-get-title node) "A top-level heading"))
        (should (equal (org-node-get-file-title node) nil))
        (should (equal (org-node-get-file-title-or-basename node)
                       expected-filename))))))

;;; org-node-test.el ends here
