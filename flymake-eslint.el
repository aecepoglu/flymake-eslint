;;; flymake-eslint.el --- A Flymake backend for Javascript using eslint  -*- lexical-binding: t; -*-

;; Version: 1.7.0
;; Author: Dan Orzechowski
;; Contributor: Terje Larsen
;; URL: https://github.com/orzechowskid/flymake-eslint
;; Package-Requires: ((emacs "26.1"))
;; Keywords: languages, tools

;;; Commentary:

;; A backend for Flymake which uses eslint.  Enable it with M-x
;; flymake-eslint-enable RET.  Alternately, configure a mode-hook for your
;; Javascript major mode of choice:

;; (add-hook 'some-js-major-mode-hook #'flymake-eslint-enable)

;; A handful of configurable options can be found in the flymake-eslint
;; customization group: view and modify them with the M-x customize-group RET
;; flymake-eslint RET.

;; License: MIT

;;; Code:

;;;; Requirements

(require 'cl-lib)
(when (featurep 'project)
  (require 'project))
(when (featurep 'json)
  (require 'json))

;;;; Customization

(defgroup flymake-eslint nil
  "Flymake checker for Javascript using eslint."
  :group 'programming
  :prefix "flymake-eslint-")

(defcustom flymake-eslint-executable '("eslint")
  "Arguments to execute `eslint'
  Example values:
    '(\"eslint\") ; to use an eslint available in exec-ptah
    '(\"npx\" \"eslint\") ; to use eslint through npx. Allows access to project-local eslint
    '(\"npm\" \"exec\" \"--\" \"eslint\") ; equivalent to \"npx\"
  
  You can also send additional arguments to eslint. For example to set eslint's --max-warnings to 13:
    '(\"eslint\" \"--max-warnings\" \"13\")
    '(\"npx\" \"eslint\" \"--max-warnings\" \"13\")"
  :type '(repeat string)
  :group 'flymake-eslint)

(defcustom flymake-eslint-show-rule-name t
  "When non-nil show eslint rule name in flymake diagnostic."
  :type 'boolean
  :group 'flymake-eslint)

(defcustom flymake-eslint-defer-binary-check nil
  "Defer the eslint binary presence check.
When non-nil, the initial check, which ensures that eslint binary
is present, is disabled.  Instead, this check is performed during
backend execution.

Useful when the value of variable `exec-path' is set dynamically
and the location of eslint might not be known ahead of time."
  :type 'boolean
  :group 'flymake-eslint)

(defcustom flymake-eslint-project-root nil
  "Buffer-local.
Set to a filesystem path to use that path as the current working
directory of the linting process."
  :type 'string
  :group 'flymake-eslint)

(defcustom flymake-eslint-prefer-json-diagnostics nil
  "Try to use the JSON diagnostic format when running eslint.
This gives more accurate diagnostics but requires having an Emacs
installation with JSON support."
  :type 'boolean
  :group 'flymake-eslint)

;;;; Variables

(defvar flymake-eslint--message-regexp
  (rx bol (* space) (group (+ num)) ":" (group (+ num)) ; line:col
      (+ space) (group (or "error" "warning"))          ; type
      (+ space) (group (+? any))                        ; message
      (>= 2 space) (group (* any)) eol)                 ; rule name
  "Regexp to match eslint messages.")

(defvar-local flymake-eslint--process nil
  "Handle to the linter process for the current buffer.")

;;;; Functions

;;;;; Public

;;;###autoload
(defun flymake-eslint-enable ()
  "Enable Flymake and flymake-eslint.
Add this function to some js major mode hook."
  (interactive)
  (make-local-variable 'flymake-eslint-project-root)
  (setq default-directory
	(or flymake-eslint-project-root
	    (when (and (featurep 'project)
		       (project-current))
	      (project-root (project-current)))
	    default-directory))
  (unless flymake-eslint-defer-binary-check
    (flymake-eslint--ensure-binary-exists))
  (flymake-mode t)
  (add-hook 'flymake-diagnostic-functions 'flymake-eslint--checker nil t))

;;;;; Private

(defun flymake-eslint--ensure-binary-exists ()
  "Ensure that `flymake-eslint-executable' exists and can be invoked with `--version'
Otherwise, throw an error and tell Flymake to disable this
backend."
  (with-temp-buffer
    (let ((x flymake-eslint-executable))
      (unless (= 0 (apply 'call-process `(,(car x) nil t (current-buffer) ,@(cdr x) "--version")))
	(error "`eslint' invocation failed. It errored with message: %s" (buffer-string))))))

(defun flymake-eslint--get-position (line column buffer)
  "Get the position at LINE and COLUMN for BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (when (and line column)
        (goto-char (point-min))
        (forward-line (1- line))
        (forward-char (1- column))
        (point)))))

(defun flymake-eslint--diag-from-eslint (eslint-diag buffer)
  "Transform ESLINT-DIAG diagnostic for BUFFER into a Flymake one."
  (let* ((beg-line (gethash "line" eslint-diag))
         (beg-col (gethash "column" eslint-diag))
         (beg-pos (flymake-eslint--get-position beg-line beg-col buffer))
         (end-line (gethash "endLine" eslint-diag))
         (end-col (gethash "endColumn" eslint-diag))
         (end-pos (if end-line
                      (flymake-eslint--get-position end-line end-col buffer)
                    (cdr (flymake-diag-region buffer beg-line))))
         (lint-rule (gethash "ruleId" eslint-diag))
         (severity (gethash "severity" eslint-diag))
         (type (if (equal severity 1) :warning :error))
         (msg (gethash "message" eslint-diag))
         (full-msg (concat
                    msg
                    (when (and flymake-eslint-show-rule-name lint-rule)
                      (format " [%s]" lint-rule)))))
    (flymake-make-diagnostic
     buffer
     beg-pos
     end-pos
     type
     full-msg
     (list :rule-name lint-rule))))

(defun flymake-eslint--report-json (eslint-stdout-buffer source-buffer)
  "Create Flymake diagnostics from the JSON diagnostic in ESLINT-STDOUT-BUFFER.
The diagnostics are reported against SOURCE-BUFFER."
  (if (featurep 'json)
      (with-current-buffer eslint-stdout-buffer
        (goto-char (point-min))
        (let* ((full-diagnostics (json-parse-buffer))
               (eslint-diags (gethash "messages"(elt full-diagnostics 0))))
          (seq-map
           (lambda (diag)
             (flymake-eslint--diag-from-eslint diag source-buffer))
           eslint-diags)))
    (error
     "Tried to parse JSON diagnostics but current Emacs does not support it.")))

(defun flymake-eslint--use-json-p ()
  "Check if eslint diagnostics should be requested to be formatted as JSON."
  (and (featurep 'json) flymake-eslint-prefer-json-diagnostics))

(defun flymake-eslint--report (eslint-stdout-buffer source-buffer)
  "Create Flymake diag messages from contents of ESLINT-STDOUT-BUFFER.
They are reported against SOURCE-BUFFER.  Return a list of
results."
  (with-current-buffer eslint-stdout-buffer
    ;; start at the top and check each line for an eslint message
    (goto-char (point-min))
    (if (looking-at-p "Error:")
        (pcase-let ((`(,beg . ,end) (with-current-buffer source-buffer
                                      (cons (point-min) (point-max))))
                    (msg (thing-at-point 'line t)))
          (list (flymake-make-diagnostic source-buffer beg end :error msg)))
      (cl-loop
       until (eobp)
       when (looking-at flymake-eslint--message-regexp)
       collect (let* ((row (string-to-number (match-string 1)))
                      (column (string-to-number (match-string 2)))
                      (type (match-string 3))
                      (msg (match-string 4))
                      (lint-rule (match-string 5))
                      (msg-text (concat (format "%s: %s" type msg)
                                        (when flymake-eslint-show-rule-name
                                          (format " [%s]" lint-rule))))
                      (type-symbol (pcase type ("warning" :warning) (_ :error)))
                      (src-pos (flymake-diag-region source-buffer row column)))
                 ;; new Flymake diag message
                 (flymake-make-diagnostic
                  source-buffer
                  (car src-pos)
                  ;; buffer might have changed size
                  (min (buffer-size source-buffer) (cdr src-pos))
                  type-symbol
                  msg-text
                  (list :rule-name lint-rule)))
       do (forward-line 1)))))

;; Heavily based on the example found at
;; https://www.gnu.org/software/emacs/manual/html_node/flymake/An-annotated-example-backend.html
(defun flymake-eslint--create-process (source-buffer callback)
  "Create linter process for SOURCE-BUFFER.
CALLBACK is invoked once linter has finished the execution.
CALLBACK accepts a buffer containing stdout from linter as its
argument."
  (when (process-live-p flymake-eslint--process)
    (kill-process flymake-eslint--process))
  (let ((format-args
         (if (flymake-eslint--use-json-p)
             '("--format" "json")
           "")))
    (setq flymake-eslint--process
          (make-process
           :name "flymake-eslint"
           :connection-type 'pipe
           :noquery t
           :buffer (generate-new-buffer " *flymake-eslint*")
           :command `(,@flymake-eslint-executable
                      "--no-color"
                      "--no-ignore"
                      ,@format-args
                      "--stdin"
                      "--stdin-filename"
                      ,(or (buffer-file-name source-buffer) (buffer-name source-buffer)))
           :sentinel
           (lambda (proc &rest ignored)
             (let ((status (process-status proc))
                   (buffer (process-buffer proc)))
               (when (and (eq 'exit status)
                          ;; make sure we're not using a deleted buffer
                          (buffer-live-p source-buffer)
                          ;; make sure we're using the latest lint process
                          (eq proc (buffer-local-value 'flymake-eslint--process
                                                       source-buffer)))
                 ;; read from eslint output
                 (funcall callback buffer))
               ;; destroy temp buffer when done or killed
               (when (memq status '(exit signal))
                 (kill-buffer buffer))))))))

(defun flymake-eslint--check-and-report (source-buffer report-fn)
  "Run eslint against SOURCE-BUFFER.
Use REPORT-FN to report results."
  (when flymake-eslint-defer-binary-check
    (flymake-eslint--ensure-binary-exists))
  (let ((diag-builder-fn
         (if (flymake-eslint--use-json-p)
             'flymake-eslint--report-json
           'flymake-eslint--report)))
    (flymake-eslint--create-process
     source-buffer
     (lambda (eslint-stdout)
       (funcall
        report-fn
        (funcall diag-builder-fn eslint-stdout source-buffer))))
    (with-current-buffer source-buffer
      (process-send-string flymake-eslint--process (buffer-string))
      (process-send-eof flymake-eslint--process))))

(defun flymake-eslint--checker (report-fn &rest _ignored)
  "Run eslint on the current buffer.
Report results using REPORT-FN.  All other parameters are
currently ignored."
  (flymake-eslint--check-and-report (current-buffer) report-fn))

;;;; Footer

(provide 'flymake-eslint)

;;; flymake-eslint.el ends here
