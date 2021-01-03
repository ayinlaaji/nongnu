;;; scroll-on-jump.el --- Scroll when jumping to a new point -*- lexical-binding: t -*-

;; Copyright (C) 2020  Campbell Barton

;; Author: Campbell Barton <ideasman42@gmail.com>

;; URL: https://gitlab.com/ideasman42/emacs-scroll-on-jump
;; Version: 0.1
;; Package-Requires: ((emacs "26.2"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Lets users call any existing function that jumps to another point,
;; adding additional (optional) scrolling functionality.
;;
;; - Re-center after the jump.
;; - Animate the scroll-motion by redrawing.

;;; Usage

;; See readme.rst.
;;

;;; Code:


;; ---------------------------------------------------------------------------
;; Custom Variables

(defcustom scroll-on-jump-duration 0.4
  "The time in allowed (in seconds) for scrolling to the next position (zero disables)."
  :group 'scroll-on-jump
  :type 'integer)

(defcustom scroll-on-jump-smooth t
  "Use smooth (pixel) scrolling, otherwise scroll by lines."
  :group 'scroll-on-jump
  :type 'boolean)

(defcustom scroll-on-jump-use-curve t
  "Apply a curve to the scroll speed, starting and ending slow."
  :group 'scroll-on-jump
  :type 'boolean)


;; ---------------------------------------------------------------------------
;; Generic Utilities

(defun scroll-on-jump--scroll-by-lines-simple (window lines also-move-point)
  "A simple version of `scroll-on-jump--scroll-by-lines'.

Move LINES in WINDOW, when ALSO-MOVE-POINT is set, the point is moved too."
  (when also-move-point
    (forward-line lines))
  (set-window-start
    window
    (save-excursion
      (goto-char (window-start window))
      (forward-line lines)
      (point))
    t))

;; Per-line Scroll.
;; return remainder of lines to scroll (matching forward-line).
(defun scroll-on-jump--scroll-by-lines (window lines also-move-point)
  "Line based scroll that optionally move the point.
Argument WINDOW The window to scroll.
Argument LINES The number of lines to scroll (signed).
Argument ALSO-MOVE-POINT When non-nil, move the POINT as well."
  (let ((lines-remainder 0))
    (when also-move-point
      (let ((lines-point-remainder (forward-line lines)))
        (unless (zerop lines-point-remainder)
          (setq lines (- lines lines-point-remainder)))))
    (unless (zerop lines)
      (set-window-start
        window
        (save-excursion
          (goto-char (window-start window))
          (setq lines-remainder (forward-line lines))
          (point))
        t)
      (when also-move-point
        (unless (zerop lines-remainder)
          (forward-line (- lines-remainder)))))
    lines-remainder))


;; Per-pixel Scroll,
;; return remainder of lines to scroll (matching forward-line).
(defun scroll-on-jump--scroll-by-pixels (window char-height delta-px also-move-point)
  "Line based scroll that optionally move the point.
Argument WINDOW The window to scroll.
Argument CHAR-HEIGHT The result of `frame-char-height'.
Argument DELTA-PX The number of pixels to scroll (signed).
Argument ALSO-MOVE-POINT When non-nil, move the POINT as well."
  (cond
    ((< delta-px 0)
      (let*
        (
          (scroll-px-prev (- char-height (window-vscroll nil t))) ;; flip.
          (scroll-px-next (+ scroll-px-prev (- delta-px))) ;; flip.
          (lines (/ scroll-px-next char-height))
          (scroll-px (- scroll-px-next (* lines char-height)))
          (lines-remainder 0))
        (unless (zerop lines)
          ;; flip
          (setq lines-remainder
            (- (scroll-on-jump--scroll-by-lines window (- lines) also-move-point)))
          (unless (zerop lines-remainder)
            (setq scroll-px char-height)))
        (set-window-vscroll window (- char-height scroll-px) t)

        (cons (- lines-remainder) (- lines))))
    ((> delta-px 0)
      (let*
        (
          (scroll-px-prev (window-vscroll nil t))
          (scroll-px-next (+ scroll-px-prev delta-px))
          (lines (/ scroll-px-next char-height))
          (scroll-px (- scroll-px-next (* lines char-height)))
          (lines-remainder 0))
        (unless (zerop lines)
          (setq lines-remainder (scroll-on-jump--scroll-by-lines window lines also-move-point))
          (unless (zerop lines-remainder)
            (setq scroll-px char-height)))
        (set-window-vscroll window scroll-px t)
        (cons lines-remainder lines)))
    ;; no lines scrolled.
    (t
      (cons 0 0))))

(defun scroll-on-jump--interpolate-ease (a b factor)
  "Blend FACTOR between A and B using ease style curvature."
  (+ a (* (- b a) (- (* 3.0 factor factor) (* 2.0 factor factor factor)))))


;; ---------------------------------------------------------------------------
;; Internal Logic


(defun scroll-on-jump--immediate-scroll (window lines-scroll _dir)
  "Non animated scroll for WINDOW to move LINES-SCROLL."
  (scroll-on-jump--scroll-by-lines-simple window lines-scroll nil))

(defun scroll-on-jump--animated-scroll-by-line (window lines-scroll dir)
  "Animated scroll WINDOW LINES-SCROLL lines along DIR direction."
  (let
    (
      (time-init (current-time))
      ;; For motion less than a window, scale down the time allowed.
      ;; This means moving a short distance wont be given the full time.
      (time-limit
        (*
          scroll-on-jump-duration
          (min 1.0 (/ (float (abs lines-scroll)) (float (window-height window))))))
      (use-curve scroll-on-jump-use-curve))

    ;; Animated scrolling (early exit on input to avoid annoying lag).
    (if (not (zerop lines-scroll))
      (let
        (
          (is-early-exit t)
          (inhibit-point-motion-hooks t)
          (lines-done-abs 0)
          (lines-scroll-abs (abs lines-scroll)))
        (while-no-input
          (while (< lines-done-abs lines-scroll-abs)
            ;; Inhibit quit in all of this logic except re-display.
            (let
              (
                (inhibit-quit t)
                ;; Number of lines to move for this redraw.
                (step
                  (let*
                    (
                      (time-elapsed (float-time (time-subtract (current-time) time-init)))
                      (factor (min 1.0 (/ time-elapsed time-limit)))
                      (lines-target
                        (floor
                          (cond
                            (use-curve
                              (scroll-on-jump--interpolate-ease 0.0 lines-scroll-abs factor))
                            (t
                              (* lines-scroll-abs factor)))))
                      (lines-remainder (- lines-target lines-done-abs)))
                    ;; Step result, we must move at least one line.
                    (* dir (max 1 lines-remainder)))))

              ;; Check if this is the last step.
              (setq lines-done-abs (+ lines-done-abs (abs step)))
              (when (> lines-done-abs lines-scroll-abs)
                (setq step (- step (* dir (- lines-done-abs lines-scroll-abs)))))

              ;; Faster alternative to scroll.
              (scroll-on-jump--scroll-by-lines-simple window step t)

              (setq lines-scroll (- lines-scroll step)))

            ;; Force `redisplay', without this redrawing can be a little choppy.
            (redisplay t))
          (setq is-early-exit nil))

        ;; ;; Re-enable when editing logic.
        (when (and (null is-early-exit) (not (zerop lines-scroll)))
          (error "Internal error, 'lines-scroll' should be zero"))

        ;; If we exit early because of input.
        (when is-early-exit
          (scroll-on-jump--scroll-by-lines-simple window lines-scroll nil)))

      ;; Non-animated scrolling (immediate).
      (scroll-on-jump--scroll-by-lines-simple window lines-scroll nil)))

  (run-window-scroll-functions window))

(defun scroll-on-jump--animated-scroll-by-px (window lines-scroll dir)
  "Animated scroll WINDOW LINES-SCROLL lines along DIR direction."
  (let
    (
      (time-init (current-time))
      ;; For motion less than a window, scale down the time allowed.
      ;; This means moving a short distance wont be given the full time.
      (time-limit
        (*
          scroll-on-jump-duration
          (min 1.0 (/ (float (abs lines-scroll)) (float (window-height window))))))
      (use-curve scroll-on-jump-use-curve)
      (char-height (frame-char-height (window-frame window))))

    ;; Animated scrolling (early exit on input to avoid annoying lag).
    (if (not (zerop lines-scroll))
      (let
        (
          (is-early-exit t)
          (inhibit-point-motion-hooks t)
          (px-done-abs 0)
          (px-scroll-abs (abs (* lines-scroll char-height)))
          (px-scroll (* lines-scroll char-height)))

        ;; Workaround for situations when the `point' starts at the window bounds.
        ;; If this happens we can't do any sub-pixel scrolling as the `point' locks scrolling.
        ;; This is only needed for pixel level scrolling.
        ;;
        ;; We can move arbitrary lines here since the final point is set at the very end.
        (forward-line dir)

        (while-no-input
          (while (< px-done-abs px-scroll-abs)
            ;; Inhibit quit in all of this logic except re-display.
            (let
              (
                (inhibit-quit t)
                ;; Number of pixels to move for this redraw.
                (step
                  (let*
                    (
                      (time-elapsed (float-time (time-subtract (current-time) time-init)))
                      (factor (min 1.0 (/ time-elapsed time-limit)))
                      (px-target
                        (floor
                          (cond
                            (use-curve
                              (scroll-on-jump--interpolate-ease 0.0 px-scroll-abs factor))
                            (t
                              (* px-scroll-abs factor)))))
                      (px-remainder (- px-target px-done-abs)))
                    ;; Step result, we must move at least one pixel.
                    (* dir (max 1 (floor px-remainder))))))

              ;; Check if this is the last step.
              (setq px-done-abs (+ px-done-abs (abs step)))
              (when (> px-done-abs px-scroll-abs)
                (setq step (- step (* dir (- px-done-abs px-scroll-abs)))))

              (pcase-let
                (
                  (`(,_lines-remainder . ,lines-handled)
                    (scroll-on-jump--scroll-by-pixels window char-height step t)))
                (setq lines-scroll (- lines-scroll lines-handled)))

              (setq px-scroll (- px-scroll step)))

            ;; Force `redisplay', without this redrawing can be a little choppy.
            (redisplay t))
          (setq is-early-exit nil))

        ;; ;; Re-enable when editing logic.
        (when (and (null is-early-exit) (not (zerop px-scroll)))
          (set-window-vscroll window 0 t)
          (error "Internal error, 'px-scroll' should be zero"))

        ;; If we exit early because of input.
        (when is-early-exit
          (set-window-vscroll window 0 t)
          (scroll-on-jump--scroll-by-lines-simple window lines-scroll nil)))

      ;; Non-animated scrolling (immediate).
      (scroll-on-jump--scroll-by-lines-simple window lines-scroll nil)))

  (run-window-scroll-functions window))

(defun scroll-on-jump--scroll-impl (window lines-scroll dir)
  (cond
    ;; No animation.
    ((zerop scroll-on-jump-duration)
      (scroll-on-jump--immediate-scroll window lines-scroll dir))
    ;; Use pixel scrolling.
    ((and scroll-on-jump-smooth (display-graphic-p))
      (scroll-on-jump--animated-scroll-by-px window lines-scroll dir))
    ;; Use line scrolling.
    (t
      (scroll-on-jump--animated-scroll-by-line window lines-scroll dir))))

(defun scroll-on-jump-auto-center (window point-prev point-next)
  "Re-frame WINDOW from POINT-PREV to POINT-NEXT, optionally animating."
  ;; Count lines, excluding the current line.
  (let ((lines (1- (count-screen-lines point-prev point-next t window))))
    (when (> lines 0)
      (let
        (
          (height (window-height window))
          (lines-scroll 0)
          (dir
            (if (< point-prev point-next)
              1
              -1)))

        (if (eq dir 1)
          (let*
            (
              (window-lines-prev (count-screen-lines (window-start window) point-prev t window))
              (window-lines-next (+ window-lines-prev lines))
              (lines-limit (max (/ height 2) window-lines-prev)))
            (when (>= window-lines-next lines-limit)
              (setq lines-scroll (- window-lines-next lines-limit))
              ;; Clamp lines-scroll by the window end
              ;; Only needed when scrolling down.
              ;;
              ;; Do this so we don't scroll past the end.
              (setq lines-scroll
                (-
                  lines-scroll
                  (save-excursion
                    (goto-char (window-end))
                    (forward-line lines-scroll))))))
          (let*
            ( ;; Note that we can't use `window-end' here as we may
              ;; be scrolled past the screen end-point.
              (window-lines-prev
                (- height (count-screen-lines (window-start window) point-prev t window)))
              (window-lines-next (+ window-lines-prev lines))
              (lines-limit (max (/ height 2) window-lines-prev)))
            (when (>= window-lines-next lines-limit)
              (setq lines-scroll (- lines-limit window-lines-next))
              ;; Clamp lines-scroll by the window start
              ;; Only needed when scrolling up.
              ;;
              ;; Even though scroll can't scroll past the start,
              ;; we don't want to try to animate scrolling up in this case.
              (setq lines-scroll
                (-
                  lines-scroll
                  (save-excursion
                    (goto-char (window-start window))
                    (forward-line lines-scroll)))))))

        (scroll-on-jump--scroll-impl window lines-scroll dir))))

  (goto-char point-next))

;; ---------------------------------------------------------------------------
;; Public Functions

;;;###autoload
(defmacro scroll-on-jump (&rest body)
  "Main macro that wraps BODY in logic that reacts to change in `point'."
  `
  (let
    ( ;; Set in case we have an error.
      (buf (current-buffer))
      (window (selected-window))

      (point-prev (point))
      (point-next nil))

    (prog1
      (save-excursion
        ;; Note, we could catch and re-raise errors,
        ;; this has the advantage that we could get the resulting cursor location
        ;; even in the case of an error.
        ;; However - this makes troubleshooting problems considerably more difficult.
        ;; As it wont show the full back-trace, only the error message.
        ;; So don't prioritize correct jumping in the case of errors and assume errors
        ;; are not something that happen after cursor motion.
        (prog1
          (progn
            ,@body)
          (setq point-next (point))))

      (cond
        ( ;; Perform animated scroll.
          (and
            ;; Buffer/Context changed.
            (eq buf (window-buffer window)) (eq buf (current-buffer)) (eq window (selected-window))

            ;; Disallow recursion.
            (not (boundp 'scroll-on-jump--resurse)))

          (let ((scroll-on-jump--resurse t))
            (scroll-on-jump-auto-center window point-prev point-next)))

        (t ;; Context changed or recursed, simply jump.
          (goto-char point-next))))))

;;;###autoload
(defmacro scroll-on-jump-interactive (fn)
  "Macro that wraps interactive call to function FN.

Use if you want to use `scroll-on-jump' for a single `key-binding',
without changing behavior anywhere else."
  `(lambda () (interactive) (scroll-on-jump (call-interactively ,fn))))

;; Helper function (not public).
(defun scroll-on-jump-advice--wrapper (old-fn &rest args)
  "Internal function use to advise using `scroll-on-jump-advice-add' (calling OLD-FN with ARGS)."
  (scroll-on-jump (apply old-fn args)))

;;;###autoload
(defmacro scroll-on-jump-advice-add (fn)
  "Add advice to FN, to instrument it with scrolling capabilities."
  (advice-add fn :around #'scroll-on-jump-advice--wrapper))

;;;###autoload
(defmacro scroll-on-jump-advice-remove (fn)
  "Remove advice on FN added by `scroll-on-jump-advice-add'."
  (advice-remove fn #'scroll-on-jump-advice--wrapper))

(provide 'scroll-on-jump)

;;; scroll-on-jump.el ends here
