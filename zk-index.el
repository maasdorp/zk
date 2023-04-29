;;; zk-index.el --- Index for zk   -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Grant Rosson

;; Author: Grant Rosson <https://github.com/localauthor>
;; Created: January 25, 2022
;; License: GPL-3.0-or-later
;; Version: 0.8
;; Homepage: https://github.com/localauthor/zk

;; Package-Requires: ((emacs "27.1")(zk "0.3"))

;; This program is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
;; for more details.

;; You should have received a copy of the GNU General Public License along
;; with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ZK-Index: A sortable, searchable, narrowable, semi-persistent selection of
;; notes, in the form of clickable links.

;; To enable integration with Embark, include '(zk-index-setup-embark)' in
;; your init config.

;;; Code:

(require 'zk)
(require 'hl-line)

;;; Custom Variables

(defgroup zk-index nil
  "Index interface for zk."
  :group 'text
  :group 'files
  :prefix "zk-index")

(defcustom zk-index-buffer-name "*ZK-Index*"
  "Name for ZK-Index buffer."
  :type 'string)

(defcustom zk-index-format-function 'zk-index--format-candidates
  "Default formatting function for ZK-Index candidates."
  :type 'function)

(defcustom zk-index-invisible-ids t
  "If non-nil, IDs will not be visible in the index."
  :type 'boolean)

(defcustom zk-index-format "%t %i"
  "Default format for candidates in the index."
  :type 'string)

(defcustom zk-index-prefix "-> "
  "String to prepend to note names in ZK-Index."
    :type 'string)

(defcustom zk-index-auto-scroll t
  "Enable automatically showing note at point in ZK-Index."
  :type 'boolean)

(defcustom zk-index-view-hide-cursor t
  "Hide cursor in `zk-index-view-mode'."
  :type 'boolean)

(defcustom zk-index-button-display-function 'zk-index-button-display-action
  "Function called when buttons pressed in ZK-Index and ZK-Desktop.
The function is called by `zk-index-button-action'. A custom
function must take two arguments, FILE and BUFFER respectively.
See the default function `zk-index-button-display-action' for an
example."
  :type 'function)

;;; ZK-Index Major Mode Settings

(defvar zk-index-mode-line-orig nil
  "Value of `mode-line-misc-info' at the start of mode.")

(defvar zk-index-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'zk-index-next-line)
    (define-key map (kbd "p") #'zk-index-previous-line)
    (define-key map (kbd "v") #'zk-index-view-note)
    (define-key map (kbd "o") #'other-window)
    (define-key map (kbd "f") #'zk-index-focus)
    (define-key map (kbd "s") #'zk-index-search)
    (define-key map (kbd "g") #'zk-index-query-refresh)
    (define-key map (kbd "c") #'zk-index-current-notes)
    (define-key map (kbd "i") #'zk-index-refresh)
    (define-key map (kbd "S") #'zk-index-sort-size)
    (define-key map (kbd "M") #'zk-index-sort-modified)
    (define-key map (kbd "C") #'zk-index-sort-created)
    (define-key map (kbd "RET") #'zk-index-open-note)
    (define-key map (kbd "q") #'delete-window)
    (make-composed-keymap map tabulated-list-mode-map))
  "Keymap for ZK-Index buffer.")

(define-derived-mode zk-index-mode nil "ZK-Index"
  "Mode for `zk-index'.
\\{zk-index-mode-map}"
  (setq zk-index-mode-line-orig mode-line-misc-info)
  (read-only-mode)
  (hl-line-mode)
  (make-local-variable 'show-paren-mode)
  (setq-local show-paren-mode nil)
  (setq cursor-type nil))


;;; Declarations

(defvar zk-desktop-directory)
(defvar zk-index-last-sort-function nil)
(defvar zk-index-last-format-function nil)
(defvar zk-index-query-mode-line nil)
(defvar zk-index-query-terms nil)
(defvar zk-search-history)

(declare-function zk-file-p zk)
(declare-function zk--grep-id-list zk)


;;; Embark Integration

(defvar embark-multitarget-actions)
(defvar embark-target-finders)
(defvar embark-exporters-alist)

(defun zk-index-setup-embark ()
  "Setup Embark integration for zk.
Adds zk-id as an Embark target, and adds `zk-id-map' and
`zk-file-map' to `embark-keymap-alist'."
  (with-eval-after-load 'embark
    (add-to-list 'embark-multitarget-actions 'zk-index)
    (add-to-list 'embark-multitarget-actions 'zk-copy-link-and-title)
    (add-to-list 'embark-multitarget-actions 'zk-follow-link-at-point)
    (add-to-list 'embark-target-finders 'zk-index-embark-target)
    (add-to-list 'embark-exporters-alist '(zk-file . zk-index))
    (define-key zk-id-map (kbd "i") #'zk-index-insert-link)))

(defun zk-index-embark-target ()
  "Target zk-id of button at point in ZK-Index and ZK-Desktop."
  (when (zk-index--button-at-point-p)
    (save-excursion
      (beginning-of-line)
      (re-search-forward zk-id-regexp (line-end-position)))
    (let ((zk-id (match-string-no-properties 1)))
      `(zk-id ,zk-id . ,(cons (line-beginning-position) (line-end-position))))))

;;; Formatting

(defun zk-index--format-candidates (&optional files format)
  "Return a list of FILES as formatted candidates, following FORMAT.
See `zk--format' for details about FORMAT. If nil, `zk-index-format'
will be used by default. FILES must be a list of filepaths. If nil,
all files in `zk-directory' will be returned as formatted candidates."
  (let* ((format (or format zk-index-format))
         (list (or files
                   (zk--directory-files)))
         (output))
    (dolist (file list)
      (when (string-match (zk-file-name-regexp) file)
        (let ((id (if zk-index-invisible-ids
                      (propertize (match-string 1 file) 'invisible t)
                    (match-string 1 file)))
              (title (replace-regexp-in-string
                      zk-file-name-separator
                      " "
                      (match-string 2 file))))
          (push (zk--format format id title) output))))
    output))

;;; Main Stack

;;;###autoload
(defun zk-index (&optional files format-fn sort-fn buf-name)
  "Open ZK-Index, with optional FILES, FORMAT-FN, SORT-FN, BUF-NAME."
  (interactive)
  (setq zk-index-last-format-function format-fn)
  (setq zk-index-last-sort-function sort-fn)
  (let ((inhibit-message nil)
        (inhibit-read-only t)
        (buf-name (or buf-name
                      zk-index-buffer-name))
        (list (or files
                  (zk--directory-files t))))
    (if (not (get-buffer buf-name))
        (progn
          (when zk-default-backlink
            (unless (zk-file-p)
              (zk-find-file-by-id zk-default-backlink)))
          (generate-new-buffer buf-name)
          (with-current-buffer buf-name
            (setq default-directory (expand-file-name zk-directory))
            (zk-index-mode)
            (zk-index--sort list format-fn sort-fn)
            (setq truncate-lines t)
            (goto-char (point-min)))
          (pop-to-buffer buf-name
                         '(display-buffer-at-bottom)))
      (when files
        (zk-index-refresh files format-fn sort-fn buf-name))
      (pop-to-buffer buf-name
                     '(display-buffer-at-bottom)))))

(defun zk-index-refresh (&optional files format-fn sort-fn buf-name)
  "Refresh the index.
Optionally refresh with FILES, using FORMAT-FN, SORT-FN, BUF-NAME."
  (interactive)
  (let ((inhibit-message t)
        (inhibit-read-only t)
        (files (or files
                   (zk--directory-files t)))
        (sort-fn (or sort-fn
                     (setq zk-index-last-sort-function nil)))
        (buf-name (or buf-name
                      zk-index-buffer-name))
        (line))
    (setq zk-index-last-format-function format-fn)
    (setq zk-index-last-sort-function sort-fn)
    (with-current-buffer buf-name
      (setq line (line-number-at-pos))
      (erase-buffer)
      (zk-index--reset-mode-name)
      (zk-index--sort files format-fn sort-fn)
      (goto-char (point-min))
      (setq truncate-lines t)
      (unless (zk-index-narrowed-p buf-name)
        (progn
          (zk-index--reset-mode-line)
          (forward-line line))))))

(defun zk-index--sort (files &optional format-fn sort-fn)
  "Sort FILES, with option FORMAT-FN and SORT-FN."
  (let* ((sort-fn (or sort-fn
                      'zk-index--sort-modified))
         (files (if (zk--singleton-p files)
                    files
                  (nreverse (funcall sort-fn files)))))
    (funcall #'zk-index--format files format-fn)))

(defun zk-index--format (files &optional format-fn)
  "Format FILES with optional custom FORMAT-FN."
  (let* ((format-fn (or format-fn
                        zk-index-format-function))
         (candidates (funcall format-fn files)))
    (zk-index--insert candidates)))

(eval-and-compile
  (define-button-type 'zk-index
    'follow-link t
    'face 'default))

(defun zk-index--insert (candidates)
  "Insert CANDIDATES into ZK-Index."
  (when (eq major-mode 'zk-index-mode)
    (garbage-collect)
    (dolist (file candidates)
      (insert zk-index-prefix file "\n"))
    (goto-char (point-min))
    (zk-index-make-buttons)
    (zk-index--set-mode-name (format " [%s]" (length candidates)))))

;;;###autoload
(defun zk-index-make-buttons ()
  "Make buttons in ZK-Index."
  (interactive)
  (let ((inhibit-read-only t)
        (ids (zk--id-list)))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward zk-id-regexp nil t)
        (let* ((beg (line-beginning-position))
               (end (line-end-position))
               (id (match-string-no-properties 1)))
          (when (member id ids)
            (beginning-of-line)
            (make-text-button beg end
                              'type 'zk-index
                              'action 'zk-index-button-action
                              'help-echo 'zk-index-help-echo)
            (when zk-index-invisible-ids
              (beginning-of-line)
              (re-search-forward id)
              (replace-match
               (propertize id 'invisible t)))
            (goto-char (match-end 0))))))))

;;;; Utilities

(defun zk-index-button-display-action (file buffer)
  "Function to display FILE or BUFFER on button press in Index and Desktop."
  ;; TODO check that zk-desktop is loaded
  (if (and zk-desktop-directory
	   (file-in-directory-p zk-desktop-directory
				default-directory))
      ;; display action for ZK-Desktop
      (progn
        (if (one-window-p)
            (pop-to-buffer buffer
                           (display-buffer-in-direction
                            buffer
                            '((direction . bottom)
                              (window-height . 0.5))))
          (find-file-other-window file)))
    ;; display action for ZK-Index
    (if (one-window-p)
        (pop-to-buffer buffer
                       (display-buffer-in-direction
                        buffer
                        '((direction . top)
                          (window-height . 0.6))))
      (find-file-other-window file))))

(defun zk-index-button-action (_)
  "Action taken when `zk-index' button is pressed."
  (let* ((id (zk-index--button-at-point-p))
         (file (zk--parse-id 'file-path id))
         (buffer
          (find-file-noselect file)))
    (funcall zk-index-button-display-function file buffer)))

(defun zk-index-help-echo (win _obj pos)
  "Generate help-echo zk-index button in WIN at POS."
  (with-selected-window win
    (let ((id (save-excursion
                (goto-char pos)
                (re-search-forward zk-id-regexp (line-end-position) t)
                (match-string-no-properties 0))))
      (format "%s" (zk--parse-id 'title id)))))

(defun zk-index-narrowed-p (buf-name)
  "Return t when index is narrowed in buffer BUF-NAME."
  (with-current-buffer (or buf-name
                           zk-index-buffer-name)
    (if (< (count-lines (point-min) (point-max))
           (length (zk--directory-files)))
        t nil)))

;;; Index Search and Focus Functions

;;;; Index Search
;; narrow index based on search of notes' full text

(defun zk-index-search ()
  "Narrow index based on regexp search of note contents."
  (interactive)
  (if (eq major-mode 'zk-index-mode)
      (zk-index-refresh
       (zk-index-query-files)
       zk-index-last-format-function
       zk-index-last-sort-function
       (buffer-name))
    (user-error "Not in a ZK-Index")))

;;;; Index Focus
;; narrow index based on search of note titles (case sensitive)
;; an alternative to consult-focus-lines

(defun zk-index-focus ()
  "Narrow index based on regexp search of note titles."
  (interactive)
  (if (eq major-mode 'zk-index-mode)
      (zk-index-refresh
       (zk-index-query-files)
       zk-index-last-format-function
       zk-index-last-sort-function
       (buffer-name))
    (user-error "Not in a ZK-Index")))

;;;; Low-level Query Functions

(defvar zk-index-query-terms nil
  "Ordered list of current query terms.
Takes form of (COMMAND . TERM), where COMMAND is 'ZK-INDEX-FOCUS
or 'ZK-INDEX-SEARCH, and TERM is the query string. Recent
items listed first.")

(defun zk-index-query-files ()
  "Return narrowed list of notes, based on focus or search query."
  (let* ((command this-command)
         (scope (if (zk-index-narrowed-p (buffer-name))
                    (zk-index--current-id-list (buffer-name))
                  (setq zk-index-query-terms nil)
                  (zk--id-list)))
         (string (read-string (cond ((eq command 'zk-index-focus)
                                     "Focus: ")
                                    ((eq command 'zk-index-search)
                                     "Search: "))
                              nil 'zk-search-history))
         (query (cond
                 ((eq command 'zk-index-focus)
                  (zk--id-list string))
                 ((eq command 'zk-index-search)
                  (zk--grep-id-list string))))
         (ids (mapcar (lambda (x) (when (member x scope) x))
                      query))
         (files (zk--parse-id 'file-path (remq nil ids))))
    (add-to-history 'zk-search-history string)
    (when files
      (let ((mode-line (zk-index-query-mode-line command string)))
        (setq zk-index-query-mode-line mode-line)
        (zk-index--set-mode-line mode-line)
        (zk-index--reset-mode-name)))
    (when (stringp files)
      (setq files (list files)))
    (or files
        (error "No matches for \"%s\"" string))))

(defun zk-index-query-refresh ()
  "Refresh narrowed index, based on last focus or search query."
  (interactive)
  (let ((mode mode-name)
        (files (zk-index--current-file-list)))
    (unless (stringp files)
      (zk-index-refresh files
                        nil
                        zk-index-last-sort-function)
      (setq mode-name mode))))

(defun zk-index-query-mode-line (query-command string)
  "Generate new mode line after query.
QUERY-COMMAND is either `zk-index-focus' or `zk-index-search',
with query term STRING."
  (push (cons query-command string) zk-index-query-terms)
  ;; Sort the different terms into two lists
  (let (focused
        searched)
    (dolist (term zk-index-query-terms)
      (if (equal (car term) 'zk-index-focus)
          (push term focused)
        (push term searched)))
    ;; Format each list and update appropriate list
    (let* ((formatted
            (mapcar (lambda (term-list)
                      (when term-list
                        ;; (CMD . STRING)
                        (cons (caar term-list)
                              (mapconcat #'cdr term-list "\" + \""))))
                    ;;      CAR     CDR
                    (list focused searched))))
      (concat "["
              (mapconcat (lambda (query)
                           (when query
                             (concat
                              (capitalize
                               (caddr
                                (split-string (symbol-name (car query)) "-")))
                              ": \""
                              (cdr query))))
                         ;; Put the last query type at the end
                         (sort (remq nil formatted)
                               (lambda (a _b)
                                 (not (equal (car a) query-command))))
                         "\" | ")
              "\"]"))))

(defun zk-index--set-mode-line (string)
  "Add STRING to mode-line in `zk-index-mode'."
  (when (eq major-mode 'zk-index-mode)
    (setq-local mode-line-misc-info string)))

(defun zk-index--reset-mode-line ()
  "Reset mode-line in `zk-index-mode'."
  (setq-local mode-line-misc-info zk-index-mode-line-orig)
  (setq zk-index-query-mode-line nil
        zk-index-query-terms nil))

(defun zk-index--current-id-list (buf-name)
  "Return list of IDs for index in BUF-NAME, as filepaths."
  (let (ids)
    (with-current-buffer (or buf-name
                             zk-index-buffer-name)
      (save-excursion
        (goto-char (point-min))
        (save-match-data
          (while (re-search-forward zk-id-regexp nil t)
            (push (match-string-no-properties 0) ids)))
        ids))))

;;; Index Sort Functions

(defun zk-index-sort-modified ()
  "Sort index by last modified."
  (interactive)
  (if (eq major-mode 'zk-index-mode)
      (progn
        (zk-index-refresh (zk-index--current-file-list)
                          zk-index-last-format-function
                          #'zk-index--sort-modified
                          (buffer-name))
        (zk-index--set-mode-name " by modified"))
    (user-error "Not in a ZK-Index")))

(defun zk-index-sort-created ()
  "Sort index by date created."
  (interactive)
  (if (eq major-mode 'zk-index-mode)
      (progn
        (zk-index-refresh (zk-index--current-file-list)
                          zk-index-last-format-function
                          #'zk-index--sort-created
                          (buffer-name))
        (zk-index--set-mode-name " by created"))
    (user-error "Not in a ZK-Index")))

(defun zk-index-sort-size ()
  "Sort index by size."
  (interactive)
  (if (eq major-mode 'zk-index-mode)
      (progn
        (zk-index-refresh (zk-index--current-file-list)
                          zk-index-last-format-function
                          #'zk-index--sort-size
                          (buffer-name))
        (zk-index--set-mode-name " by size"))
    (user-error "Not in a ZK-Index")))

(defun zk-index--set-mode-name (string)
  "Add STRING to `mode-name' in `zk-index-mode'."
  (when (eq major-mode 'zk-index-mode)
    (setq mode-name (concat mode-name string))))

(defun zk-index--reset-mode-name ()
  "Reset `mode-name' in `zk-index-mode'."
  (setq mode-name "ZK-Index"))

(defun zk-index--current-file-list ()
  "Return list files in current index."
  (let* ((ids (zk-index--current-id-list (buffer-name)))
         (files (zk--parse-id 'file-path ids)))
    (when files
      files)))

(defun zk-index--sort-created (list)
  "Sort LIST for latest created."
  (let ((ht (make-hash-table :test #'equal :size 5000)))
    (dolist (x list)
      (puthash x (zk--parse-file 'id x) ht))
    (sort list
          (lambda (a b)
            (let ((one
                   (gethash a ht))
                  (two
                   (gethash b ht)))
              (string< two one))))))

(defun zk-index--sort-modified (list)
  "Sort LIST for latest modification."
  (let ((ht (make-hash-table :test #'equal :size 5000)))
    (dolist (x list)
      (puthash x (file-attribute-modification-time (file-attributes x)) ht))
    (sort list
          (lambda (a b)
            (let ((one
                   (gethash a ht))
                  (two
                   (gethash b ht)))
              (time-less-p two one))))))

(defun zk-index--sort-size (list)
  "Sort LIST for latest modification."
  (sort list
        (lambda (a b)
          (> (file-attribute-size (file-attributes a))
             (file-attribute-size (file-attributes b))))))

;;; ZK-Index Keymap Commands

(defun zk-index-open-note ()
  "Open note."
  (interactive)
  (beginning-of-line)
  (push-button nil t))

(defvar-local zk-index-view--kill nil)

(defun zk-index-view-note ()
  "View note in `zk-index-view-mode'."
  (interactive)
  (beginning-of-line)
  (let* ((id (zk-index--button-at-point-p))
        (kill (unless (get-file-buffer (zk--parse-id 'file-path id))
                t)))
    (push-button nil t)
    (setq-local zk-index-view--kill kill)
    (zk-index-view-mode)))

(defun zk-index-current-notes ()
  "Open ZK-Index listing currently open notes."
  (interactive)
  (zk-index
   (zk--current-notes-list)
   zk-index-last-format-function
   zk-index-last-sort-function))

(defun zk-index--button-at-point-p (&optional pos)
  "Return zk-id when `zk-index' button is at point.
Takes an option POS position argument."
  (let ((button (or pos
                    (button-at (point)))))
    (when (and button
               (or (eq (button-type button) 'zk-index)
                   (eq (button-type button) 'zk-desktop)))
      (save-excursion
        (re-search-forward zk-id-regexp)
        (match-string-no-properties 1)))))

(defun zk-index-insert-link (&optional id)
  "Insert zk-link in `other-window' for button ID at point."
  (interactive)
  (let ((id (or id
                (zk-index--button-at-point-p))))
    (with-selected-window (other-window-for-scrolling)
      (zk-insert-link id)
      (newline))))

(defvar-local zk-index-view--cursor nil)

(define-minor-mode zk-index-view-mode
  "Minor mode for `zk-index-auto-scroll'."
  :init-value nil
  :global nil
  :keymap '(((kbd "n") . zk-index-next-line)
            ((kbd "p") . zk-index-previous-line)
            ([remap read-only-mode] . zk-index-view-mode)
            ((kbd "q") . quit-window))
  (if zk-index-view-mode
      (progn
        (read-only-mode)
        (use-local-map zk-index-mode-map)
        (when zk-index-view-hide-cursor
          (progn
            (scroll-lock-mode 1)
            (setq-local zk-index-view--cursor
                        cursor-type)
            (setq-local cursor-type nil))))
    (read-only-mode -1)
    (use-local-map nil)
    (when zk-index-view-hide-cursor
      (scroll-lock-mode -1)
      (setq-local cursor-type (or zk-index-view--cursor
                                  t)))))

(defun zk-index-next-line ()
  "Move to next line.
If `zk-index-auto-scroll' is non-nil, show note in other window."
  (interactive)
  (let ((split-width-threshold nil))
    (if zk-index-auto-scroll
        (progn
          (cond ((not (zk-file-p)))
                (zk-index-view--kill
                 (kill-buffer)
                 (other-window -1))
                ((not zk-index-view--kill)
                 (zk-index-view-mode)
                 (other-window -1)))
          (forward-button 1)
          (hl-line-highlight)
          (unless (looking-at-p "[[:space:]]*$")
            (zk-index-view-note)))
      (forward-button 1))))

(defun zk-index-previous-line ()
  "Move to previous line.
If `zk-index-auto-scroll' is non-nil, show note in other window."
  (interactive)
  (let ((split-width-threshold nil))
    (if zk-index-auto-scroll
        (progn
          (cond ((not (zk-file-p)))
                (zk-index-view--kill
                 (kill-buffer)
                 (other-window -1))
                ((not zk-index-view--kill)
                 (zk-index-view-mode)
                 (other-window -1)))
          (forward-button -1)
          (hl-line-highlight)
          (unless (looking-at-p "[[:space:]]*$")
            (zk-index-view-note)))
      (forward-button -1))))

;;;###autoload
(defun zk-index-switch-to-index ()
  "Switch to ZK-Index buffer."
  (interactive)
  (let ((buffer zk-index-buffer-name))
    (unless (get-buffer buffer)
      (progn
        (generate-new-buffer buffer)
        (zk-index-refresh)))
    (switch-to-buffer buffer)))


(provide 'zk-index)

;;; zk-index.el ends here
