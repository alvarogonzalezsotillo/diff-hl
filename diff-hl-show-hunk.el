;;; diff-hl-show-hunk.el --- Integrate popup/posframe and diff-hl-diff-goto-hunk -*- lexical-binding: t -*-

;; Copyright (C) 2020  Free Software Foundation, Inc.

;; Author: Álvaro González <alvarogonzalezsotillo@gmail.com>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `diff-hl-show-hunk' shows a popup with the modified hunk at point.
;; `diff-hl-show-hunk-function' contains the backend used to show the
;; hunk. Its default value is `diff-hl-show-hunk-inline-popup', that
;; shows diffs inline using overlay. There is another built-in backend:
;; `diff-hl-show-hunk-posframe' (based on posframe). Other backends (for
;; example based on `pos-tip') could also be implemented.
;;
;; `diff-hl-show-hunk-mode' adds the following keybindings:
;;
;;   - `diff-hl-show-hunk': C-x v *
;;   - `diff-hl-show-hunk-next': C-x v }
;;   - `diff-hl-show-hunk-previous': C-x v {
;;
;; `diff-hl-show-hunk-mouse-mode' includes all the keybindings of
;; `diff-hl-show-hunk-mode', and adds `diff-hl-show-hunk' when
;; clicking in the margin or the fringe.
;;
;; To use one or both in all buffers:
;;
;;   (global-diff-hl-show-hunk-mode)
;;
;; and/or
;;
;;   (global-diff-hl-show-hunk-mouse-mode)

;;; Code:

(require 'inline-popup)
(require 'diff-hl)

(defvar diff-hl-show-hunk-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (concat diff-hl-command-prefix  "*") #'diff-hl-show-hunk)
    (define-key map (concat diff-hl-command-prefix  "{") #'diff-hl-show-hunk-previous)
    (define-key map (concat diff-hl-command-prefix  "}") #'diff-hl-show-hunk-next)
    map)
  "Keymap for command `diff-hl-show-hunk-mode'.")

(defvar diff-hl-show-hunk-mouse-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<left-margin> <mouse-1>") 'diff-hl-show-hunk--click)
    (define-key map (kbd "<right-margin> <mouse-1>") 'diff-hl-show-hunk--click)
    (define-key map (kbd "<left-fringe> <mouse-1>") 'diff-hl-show-hunk--click)
    (define-key map (kbd "<right-fringe> <mouse-1>") 'diff-hl-show-hunk--click)
    (set-keymap-parent map diff-hl-show-hunk-mode-map)
    map)
  "Keymap for command `diff-hl-show-hunk-mouse-mode'.")

(defvar diff-hl-show-hunk-buffer-name "*diff-hl-show-hunk-buffer*"
  "Name of the posframe used by diff-hl-show-hunk.")

(defvar diff-hl-show-hunk--original-window nil
  "The vc window of which the hunk is shown.")

(defvar diff-hl-show-hunk--original-buffer nil
  "The vc buffer of which the hunk is shown.")

(defvar diff-hl-show-hunk--original-content nil
  "The original content of the hunk.")

(defgroup diff-hl-show-hunk nil
  "Show vc diffs in a posframe or popup."
  :group 'diff-hl)

;; FIXME: Should this be a defcustom?
(defcustom diff-hl-show-hunk-boundary "^@@.*@@"
  "Regex that marks the boundary of a hunk in *vc-diff* buffer."
  :type 'string)

(defcustom diff-hl-show-hunk-function 'diff-hl-show-hunk-inline-popup
  "The function used to render the hunk.
The function receives as first parameter a buffer with the
contents of the hunk, and as second parameter the line number
corresponding to the clicked line in the original buffer."
  :type '(choice
          (const :tag "Show inline" diff-hl-show-hunk-inline-popup)
          (const :tag "Show using posframe" diff-hl-show-hunk-posframe)))

(defvar diff-hl-show-hunk--hide-function nil
  "Function to call to close the shown hunk.")

(defun diff-hl-show-hunk-hide ()
  "Hide the current shown hunk."
  (interactive)
  (if diff-hl-show-hunk--original-window
      (select-window diff-hl-show-hunk--original-window))
  (setq diff-hl-show-hunk--original-window nil)
  (if (buffer-live-p diff-hl-show-hunk--original-buffer)
      (switch-to-buffer diff-hl-show-hunk--original-buffer))
  (setq diff-hl-show-hunk--original-buffer nil)
  (with-current-buffer (get-buffer-create diff-hl-show-hunk-buffer-name)
    (read-only-mode -1)
    (erase-buffer))
  (when diff-hl-show-hunk--hide-function
    (let ((hidefunc diff-hl-show-hunk--hide-function))
      (setq diff-hl-show-hunk--hide-function nil)
      (funcall hidefunc))))

(defface diff-hl-show-hunk-clicked-line-face
  '((t (:inverse-video t)))
  "Face for the clicked line in the diff output.")

(defun diff-hl-show-hunk-ignorable-command-p (command)
  "Decide if COMMAND is a command allowed while showing the current hunk."
  (member command '(ignore diff-hl-show-hunk handle-switch-frame diff-hl-show-hunk--click)))

(defun diff-hl-show-hunk--compute-diffs ()
  "Compute diffs using funcions of diff-hl.
Then put the differences in *diff-hl-show-hunk-diff-buffer*
buffer, and set the point in that buffer to the corresponding
line of the original buffer."
  (defvar vc-sentinel-movepoint)
  (let* ((buffer (or (buffer-base-buffer) (current-buffer)))
         (line (line-number-at-pos))
         (dest-buffer "*diff-hl-show-hunk-diff-buffer*"))
    (with-current-buffer buffer
      (diff-hl-diff-buffer-with-head (buffer-file-name buffer) dest-buffer)
      (switch-to-buffer dest-buffer)
      (diff-hl-diff-skip-to line)
      (setq vc-sentinel-movepoint (point)))
    dest-buffer))

(defun diff-hl-show-hunk--fill-original-content (content)
  "Extracts the lines starting with '-' from CONTENT and save them."
  (let* ((lines (split-string content "[\n\r]+" ))
         (original-lines (cl-remove-if-not (lambda (l) (string-match-p "^-.*" l)) lines))
         (original-lines (mapcar (lambda (l) (substring l 1)) original-lines))
         (content (string-join original-lines "\n")))
    (setq diff-hl-show-hunk--original-content content)))

(defun diff-hl-show-hunk-buffer ()
  "Create the buffer with the contents of the hunk at point.
The buffer has the point in the corresponding line of the hunk.
Returns a list with the buffer and the line number of the clicked line."
  (let ((content)
        (point-in-buffer)
        (line)
        (line-overlay)
         ;; https://emacs.stackexchange.com/questions/35680/stop-emacs-from-updating-display
        (inhibit-redisplay t)
        (buffer (get-buffer-create diff-hl-show-hunk-buffer-name)))

    ;; Get differences
    (save-window-excursion
      (save-excursion
        (with-current-buffer (diff-hl-show-hunk--compute-diffs)
          (setq content (buffer-substring-no-properties (point-min) (point-max)))
          (setq point-in-buffer (point)))))

    (with-current-buffer buffer
      (read-only-mode -1)
      (erase-buffer)
      (insert content)

      ;; Highlight the clicked line
      (goto-char point-in-buffer)
      (setq line-overlay (make-overlay (point-at-bol) (min (point-max) (1+ (point-at-eol)))))
      (overlay-put line-overlay 'face 'diff-hl-show-hunk-clicked-line-face)

      ;; diff-mode, highlight hunks boundaries
      (diff-mode)
      ;; FIXME: I think these are always hidden now?
      (highlight-regexp diff-hl-show-hunk-boundary)
      (read-only-mode 1)

      ;; Find the hunk and narrow to it
      (re-search-backward diff-hl-show-hunk-boundary nil 1)
      (forward-line 1)
      (let* ((start (point)))
        (re-search-forward diff-hl-show-hunk-boundary nil 1)
        (move-beginning-of-line nil)
        (narrow-to-region start (point)))

      ;; Store original content
      (let ((content (buffer-string)))
        (diff-hl-show-hunk--fill-original-content content))

      ;; Come back to the clicked line
      (goto-char (overlay-start line-overlay))

      (setq line (line-number-at-pos)))

    (list buffer line)))

(defun diff-hl-show-hunk--click (event)
  "Called when user clicks on margins.  EVENT is click information."
  (interactive "e")
  ;; Go the click's position.
  (posn-set-point (event-start event))
  (diff-hl-show-hunk))

(defun diff-hl-show-hunk--previousp (buffer)
  "Decide if there is a previous hunk/change in BUFFER."
  (ignore-errors
    (with-current-buffer buffer
      (save-excursion
        (diff-hl-previous-hunk)))))

(defun diff-hl-show-hunk--nextp (buffer)
  "Decide if the is a next hunk/change in BUFFER."
  (ignore-errors
    (with-current-buffer buffer
      (save-excursion
        (diff-hl-next-hunk)))))

(defvar diff-hl-show-hunk--inline-popup-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "p") #'diff-hl-show-hunk-previous)
    (define-key map (kbd "n") #'diff-hl-show-hunk-next)
    (define-key map (kbd "c") #'diff-hl-show-hunk-copy-original-text)
    (define-key map (kbd "r") #'diff-hl-show-hunk-revert-hunk)
    (define-key map (kbd "C-x v {") #'diff-hl-show-hunk-previous)
    (define-key map (kbd "C-x v }") #'diff-hl-show-hunk-next)
    map))

(defvar diff-hl-show-hunk--hide-function)

;;;###autoload
(defun diff-hl-show-hunk-inline-popup (buffer line)
  "Implementation to show the hunk in a inline popup.
BUFFER is a buffer with the hunk, and the central line should be LINE."
  (inline-popup-hide)
  (setq diff-hl-show-hunk--hide-function #'inline-popup-hide)
  (let* ((lines (split-string (with-current-buffer buffer (buffer-string)) "[\n\r]+" ))
         (line (max 0 (- line 1)))
         (propertize-line (lambda (l)
                            (propertize l 'face
                                        (cond ((string-prefix-p "+" l)
                                               'diff-added)
                                              ((string-prefix-p "-" l)
                                               'diff-removed)))))
         (propertized-lines (mapcar propertize-line lines))
         (clicked-line (propertize (nth line lines) 'face 'diff-hl-show-hunk-clicked-line-face)))
    (setcar (nthcdr line propertized-lines) clicked-line)
    (inline-popup-show propertized-lines
                       "Diff with HEAD"
                       "(q)Quit  (p)Previous  (n)Next  (r)Revert  (c)Copy original"
                       diff-hl-show-hunk--inline-popup-map
                       #'diff-hl-show-hunk-hide)
    (inline-popup-scroll-to line)))

(defun diff-hl-show-hunk-copy-original-text ()
  "Extracts all the lines from BUFFER starting with '-' to the kill ring."
  (interactive)
  (kill-new diff-hl-show-hunk--original-content)
  (message "Original hunk content added to kill-ring"))

(defun diff-hl-show-hunk-revert-hunk ()
  "Dismiss the popup and prompt to revert the current diff hunk."
  (interactive)
  (diff-hl-show-hunk-hide)
  (diff-hl-revert-hunk))

;;;###autoload
(defun diff-hl-show-hunk-previous ()
  "Go to previous hunk/change and show it."
  (interactive)
  (move-beginning-of-line 1)
  (let ((buffer (if (buffer-live-p diff-hl-show-hunk--original-buffer)
                    diff-hl-show-hunk--original-buffer
                  (current-buffer))))
    (if (not (diff-hl-show-hunk--previousp buffer))
        (message "There is no previous change")
      (diff-hl-show-hunk-hide)
      (diff-hl-previous-hunk)
      (recenter)
      ;;(run-with-timer 0 nil #'diff-hl-show-hunk))))
      (diff-hl-show-hunk))))

;;;###autoload
(defun diff-hl-show-hunk-next ()
  "Go to next hunk/change and show it."
  (interactive)
  (let ((buffer (if (buffer-live-p diff-hl-show-hunk--original-buffer)
                    diff-hl-show-hunk--original-buffer
                  (current-buffer))))
    (if (not (diff-hl-show-hunk--nextp buffer))
        (message "There is no next change")
      (diff-hl-show-hunk-hide)
      (diff-hl-next-hunk)
      (recenter)
      ;;(run-with-timer 0 nil #'diff-hl-show-hunk))))
      (diff-hl-show-hunk))))

;;;###autoload
(defun diff-hl-show-hunk ()
  "Show the VC diff hunk at point.
The backend is determined by `diff-hl-show-hunk-function'.  If
not, it falls back to `diff-hl-diff-goto-hunk'."
  (interactive)
  (cond
   ((not (vc-backend buffer-file-name))
    (user-error "The buffer is not under version control"))
   ((not (diff-hl-hunk-overlay-at (point)))
    (diff-hl-previous-hunk)))
  (cond
   ((not diff-hl-show-hunk-function)
    (message "Please configure `diff-hl-show-hunk-function'")
    (diff-hl-diff-goto-hunk))
   ((let ((buffer-and-line (diff-hl-show-hunk-buffer)))
      (setq diff-hl-show-hunk--original-buffer (current-buffer))
      (setq diff-hl-show-hunk--original-window (selected-window))
      (apply diff-hl-show-hunk-function buffer-and-line))
    ;; We could fall back to `diff-hl-diff-goto-hunk', but the
    ;; current default should work in all environments (both GUI
    ;; and terminal), and if something goes wrong we better show
    ;; the error to the user.
    )))

;;;###autoload
(define-minor-mode diff-hl-show-hunk-mouse-mode
  "Enables the margin and fringe to show a posframe/popup with vc diffs when clicked.
By default, the posframe/popup shows only the current hunk, and
the line of the hunk that matches the current position is
highlighted.  The face, border and other visual preferences are
customizable.  It can be also invoked with the command
`diff-hl-show-hunk'
\\{diff-hl-show-hunk-mouse-mode-map}"
  :group 'diff-hl-show-hunk
  :lighter "")

;;;###autoload
(define-globalized-minor-mode global-diff-hl-show-hunk-mouse-mode
  diff-hl-show-hunk-mouse-mode
  diff-hl-show-hunk-mouse-mode)

;;;###autoload
(define-minor-mode diff-hl-show-hunk-mode
  "Enables a keymap with some commands of the `diff-hl-show-hunk' package
\\{diff-hl-show-hunk-mode-map}"
  :group 'diff-hl-show-hunk
  :lighter "")

;;;###autoload
(define-globalized-minor-mode global-diff-hl-show-hunk-mode
  diff-hl-show-hunk-mode
  diff-hl-show-hunk-mode)

(provide 'diff-hl-show-hunk)
;;; diff-hl-show-hunk.el ends here
