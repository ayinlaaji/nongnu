;;; hl-block-mode.el --- highlighting nested blocks -*- lexical-binding: t -*-

;; Copyright (C) 2019-2021  Campbell Barton

;; Author: Campbell Barton <ideasman42@gmail.com>

;; URL: https://gitlab.com/ideasman42/emacs-hl-block-mode
;; Version: 0.1
;; Package-Requires: ((emacs "26.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Highlight blocks surrounding the cursor.

;;; Usage

;; (hl-block-mode)        ; activate in the current buffer
;; (global-hl-block-mode) ; activate globally for all buffers
;;
;; Currently only curly braces are supported (C-family languages).


;;; Code:

(require 'seq)


;; ---------------------------------------------------------------------------
;; Custom Variables

(defcustom hl-block-bracket ?{
  "Character to use as a starting bracket (defaults to '{').
Set to nil to use all brackets."
  :group 'hl-block-mode
  :type 'symbol)

(defcustom hl-block-delay 0.2
  "Idle time to wait before highlighting."
  :group 'hl-block-mode
  :type 'float)

(defcustom hl-block-color-tint "#040404"
  "Color to add/subtract from the background each scope step."
  :group 'hl-block-mode
  :type 'float)

(defcustom hl-block-mode-lighter ""
  "Lighter for `hl-block-mode'."
  :group 'hl-block-mode
  :type 'string)


;; ---------------------------------------------------------------------------
;; Internal Variables

(defvar-local hl-block-overlay nil)

;; ---------------------------------------------------------------------------
;; Internal Functions/Macros

(defun hl-block--syntax-prev-bracket (pt)
  "A version of `syntax-ppss' to match curly braces.
PT is typically the '(point)'."
  (let ((start (ignore-errors (elt (syntax-ppss pt) 1))))
    (when start
      (if (char-equal hl-block-bracket (char-after start))
        start
        (hl-block--syntax-prev-bracket (1- start))))))

(defun hl-block--find-all-ranges (pt)
  "Return a list of ranges starting from PT, outer-most to inner-most."
  (let*
    (
      (start
        ;; find brackets
        (if hl-block-bracket
          (hl-block--syntax-prev-bracket pt)
          (ignore-errors (elt (syntax-ppss pt) 1))))
      (end
        (when start
          (or (ignore-errors (scan-sexps start 1)) pt)))
      (range-prev
        (when start
          (hl-block--find-all-ranges start))))
    (when start
      (if range-prev
        (cons (list start end) range-prev)
        (list (list start end))))))

(defun hl-block--color-values-as-string (r g b)
  "Build a color from R G B.
Inverse of `color-values'."
  (format "#%02x%02x%02x" (ash r -8) (ash g -8) (ash b -8)))

(defun hl-block--overlay-clear ()
  "Clear all overlays."
  (mapc 'delete-overlay hl-block-overlay)
  (setq hl-block-overlay nil))

(defun hl-block--overlay-refresh ()
  "Update the overlays based on the cursor location."
  (hl-block--overlay-clear)
  (let ((block-list (save-excursion (hl-block--find-all-ranges (point)))))
    (when block-list
      (let*
        (
          (block-list
            (if (cdr block-list)
              (reverse block-list)
              (cons (list (point-min) (point-max)) block-list)))
          (start-prev (nth 0 (nth 0 block-list)))
          (end-prev (nth 1 (nth 0 block-list)))
          (block-list-len (length block-list))
          (bg-color (color-values (face-attribute 'default :background)))
          (bg-color-tint (color-values hl-block-color-tint))
          ;; Check dark background is light/dark.
          (do-highlight (> 98304 (apply '+ bg-color))))
        (seq-map-indexed
          (lambda (elem_range i)
            (let*
              (
                (i-tint (- block-list-len i))
                (start (nth 0 elem_range))
                (end (nth 1 elem_range))
                (elem-overlay-start (make-overlay start start-prev))
                (elem-overlay-end (make-overlay end-prev end))
                (bg-color-blend
                  (apply 'hl-block--color-values-as-string
                    (if do-highlight
                      (cl-mapcar `(lambda (a b) (+ a (* ,i-tint b))) bg-color bg-color-tint)
                      (cl-mapcar `(lambda (a b) (- a (* ,i-tint b))) bg-color bg-color-tint)))))
              (overlay-put elem-overlay-start 'face `(:background ,bg-color-blend :extend t))
              (overlay-put elem-overlay-end 'face `(:background ,bg-color-blend :extend t))
              (add-to-list 'hl-block-overlay elem-overlay-start)
              (add-to-list 'hl-block-overlay elem-overlay-end)
              (setq start-prev start)
              (setq end-prev end)))
          (cdr block-list))))))


;; ---------------------------------------------------------------------------
;; Internal Timer Management
;;
;; This works as follows:
;;
;; - The timer is kept active as long as the local mode is enabled.
;; - Entering a buffer runs the buffer local `window-state-change-hook'
;;   immediately which checks if the mode is enabled,
;;   set up the global timer if it is.
;; - Switching any other buffer wont run this hook,
;;   rely on the idle timer it's self running, which detects the active mode,
;;   canceling it's self if the mode isn't active.
;;
;; This is a reliable way of using a global,
;; repeating idle timer that is effectively buffer local.
;;

;; Global idle timer (repeating), keep active while the buffer-local mode is enabled.
(defvar hl-block--global-timer nil)
;; When t, the timer will update buffers in all other visible windows.
(defvar hl-block--dirty-flush-all nil)
;; When true, the buffer should be updated when inactive.
(defvar-local hl-block--dirty nil)

(defun hl-block--time-callback-or-disable ()
  "Callback that run the repeat timer."

  ;; Ensure all other buffers are highlighted on request.
  (let ((is-mode-active (bound-and-true-p hl-block-mode)))
    ;; When this buffer is not in the mode, flush all other buffers.
    (cond
      (is-mode-active
        ;; Don't update in the window loop to ensure we always
        ;; update the current buffer in the current context.
        (setq hl-block--dirty nil))
      (t
        ;; If the timer ran when in another buffer,
        ;; a previous buffer may need a final refresh, ensure this happens.
        (setq hl-block--dirty-flush-all t)))

    (when hl-block--dirty-flush-all
      ;; Run the mode callback for all other buffers in the queue.
      (dolist (frame (frame-list))
        (dolist (win (window-list frame -1))
          (let ((buf (window-buffer win)))
            (when
              (and
                (buffer-local-value 'hl-block-mode buf)
                (buffer-local-value 'hl-block--dirty buf))
              (with-selected-frame frame
                (with-selected-window win
                  (with-current-buffer buf
                    (setq hl-block--dirty nil)
                    (hl-block--overlay-refresh)))))))))
    ;; Always keep the current buffer dirty
    ;; so navigating away from this buffer will refresh it.
    (when is-mode-active
      (setq hl-block--dirty t))

    (cond
      (is-mode-active
        (hl-block--overlay-refresh))
      (t ;; Cancel the timer until the current buffer uses this mode again.
        (hl-block--time-ensure nil)))))

(defun hl-block--time-ensure (state)
  "Ensure the timer is enabled when STATE is non-nil, otherwise disable."
  (cond
    (state
      (unless hl-block--global-timer
        (setq hl-block--global-timer
          (run-with-idle-timer hl-block-delay :repeat 'hl-block--time-callback-or-disable))))
    (t
      (when hl-block--global-timer
        (cancel-timer hl-block--global-timer)
        (setq hl-block--global-timer nil)))))

(defun hl-block--time-reset ()
  "Run this when the buffer changes."
  ;; Ensure changing windows doesn't leave other buffers with stale highlight.
  (cond
    ((bound-and-true-p hl-block-mode)
      (setq hl-block--dirty-flush-all t)
      (setq hl-block--dirty t)
      (hl-block--time-ensure t))
    (t
      (hl-block--time-ensure nil))))

(defun hl-block--time-buffer-local-enable ()
  "Ensure buffer local state is enabled."
  ;; Needed in case focus changes before the idle timer runs.
  (setq hl-block--dirty-flush-all t)
  (setq hl-block--dirty t)
  (hl-block--time-ensure t)
  (add-hook 'window-state-change-hook #'hl-block--time-reset nil t))

(defun hl-block--time-buffer-local-disable ()
  "Ensure buffer local state is disabled."
  (kill-local-variable 'hl-block--dirty)
  (hl-block--time-ensure nil)
  (remove-hook 'window-state-change-hook #'hl-block--time-reset t))

;; ---------------------------------------------------------------------------
;; Internal Mode Management

(defun hl-block-mode-enable ()
  "Turn on 'hl-block-mode' for the current buffer."
  (hl-block--time-buffer-local-enable))

(defun hl-block-mode-disable ()
  "Turn off 'hl-block-mode' for the current buffer."
  (hl-block--overlay-clear)
  (hl-block--time-buffer-local-disable))

(defun hl-block-mode-turn-on ()
  "Enable command `hl-block-mode'."
  (when (and (not (minibufferp)) (not (bound-and-true-p hl-block-mode)))
    (hl-block-mode 1)))

;; ---------------------------------------------------------------------------
;; Public API

;;;###autoload
(define-minor-mode hl-block-mode
  "Highlight block under the cursor."
  :group 'hl-block-mode
  :global nil
  :lighter hl-block-mode-lighter

  (cond
    (hl-block-mode
      (jit-lock-unregister 'hl-block-mode-enable)
      (hl-block-mode-enable))
    (t
      (jit-lock-unregister 'hl-block-mode-enable)
      (hl-block-mode-disable))))

;;;###autoload
(define-globalized-minor-mode
  global-hl-block-mode

  hl-block-mode hl-block-mode-turn-on
  :group 'hl-block-mode)

(provide 'hl-block-mode)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; hl-block-mode.el ends here
