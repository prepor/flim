;;; mime-parse.el --- MIME message parser

;; Copyright (C) 1994,95,96,97,98,99,2001 Free Software Foundation, Inc.

;; Author: MORIOKA Tomohiko <morioka@jaist.ac.jp>
;;	Shuhei KOBAYASHI <shuhei@aqua.ocn.ne.jp>
;; Keywords: parse, MIME, multimedia, mail, news

;; This file is part of FLIM (Faithful Library about Internet Message).

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Code:

(require 'mime-def)
(require 'luna)
(require 'std11)

(autoload 'mime-entity-body-buffer "mime")
(autoload 'mime-entity-body-start-point "mime")
(autoload 'mime-entity-body-end-point "mime")


;;; @ lexical analyzer
;;;

(defcustom mime-lexical-analyzer
  '(std11-analyze-quoted-string
    std11-analyze-domain-literal
    std11-analyze-comment
    std11-analyze-spaces
    mime-analyze-tspecial
    mime-analyze-token)
  "*List of functions to return result of lexical analyze.
Each function must have two arguments: STRING and START.
STRING is the target string to be analyzed.
START is start position of STRING to analyze.

Previous function is preferred to next function.  If a function
returns nil, next function is used.  Otherwise the return value will
be the result."
  :group 'mime
  :type '(repeat function))

(defun mime-analyze-tspecial (string start)
  (if (and (> (length string) start)
	   (memq (aref string start) mime-tspecial-char-list))
      (cons (cons 'tspecials (substring string start (1+ start)))
	    (1+ start))))

(defun mime-analyze-token (string start)
  (if (and (string-match mime-token-regexp string start)
	   (= (match-beginning 0) start))
      (let ((end (match-end 0)))
	(cons (cons 'mime-token (substring string start end))
	      end))))

;;; This hard-coded analyzer is much faster.
;;; (defun mime-lexical-analyze (string)
;;;   "Analyze STRING as lexical tokens of MIME."
;;;   (let ((len (length string))
;;;         (start 0)
;;; 	chr pos dest)
;;;     (while (< start len)
;;;       (setq chr (aref string start))
;;;       (cond
;;;        ;; quoted-string
;;;        ((eq chr ?\")
;;; 	(if (setq pos (std11-check-enclosure string ?\" ?\" nil start))
;;; 	    (setq dest (cons (cons 'quoted-string
;;; 				   (substring string (1+ start) pos))
;;; 			     dest)
;;; 		  start (1+ pos))
;;; 	(setq dest (cons (cons 'error
;;; 			       (substring string start))
;;; 			 dest)
;;; 	      start len)))
;;;        ;; comment
;;;        ((eq chr ?\()
;;; 	(if (setq pos (std11-check-enclosure string ?\( ?\) t start))
;;; 	    (setq start (1+ pos))
;;; 	  (setq dest (cons (cons 'error
;;; 				 (substring string start))
;;; 			   dest)
;;; 		start len)))
;;;        ;; spaces
;;;        ((memq chr std11-space-char-list)
;;; 	(setq pos (1+ start))
;;; 	(while (and (< pos len)
;;; 		    (memq (aref string pos) std11-space-char-list))
;;; 	  (setq pos (1+ pos)))
;;; 	(setq start pos))
;;;        ;; tspecials
;;;        ((memq chr mime-tspecial-char-list)
;;; 	(setq dest (cons (cons 'tspecials
;;; 			       (substring string start (1+ start)))
;;; 			 dest)
;;; 	      start (1+ start)))
;;;        ;; token
;;;        ((eq (string-match mime-token-regexp string start)
;;; 	    start)
;;; 	(setq pos (match-end 0)
;;; 	      dest (cons (cons 'mime-token
;;; 			       (substring string start pos))
;;; 			 dest)
;;; 	      start pos))
;;;        ;; error
;;;        (t
;;; 	(setq pos len
;;; 	      dest (cons (cons 'error
;;; 			       (substring string start pos))
;;; 			 dest)
;;; 	      start pos))))
;;;     (nreverse dest)))
(defun mime-lexical-analyze (string)
  "Analyze STRING as lexical tokens of MIME."
  (let ((ret (std11-lexical-analyze string mime-lexical-analyzer))
        prev tail)
    ;; skip leading linear-white-space.
    (while (memq (car (car ret)) '(spaces comment))
      (setq ret (cdr ret)))
    (setq prev ret
          tail (cdr ret))
    ;; remove linear-white-space.
    (while tail
      (if (memq (car (car tail)) '(spaces comment))
          (progn
            (setcdr prev (cdr tail))
            (setq tail (cdr tail)))
        (setq prev (cdr prev)
              tail (cdr tail))))
    ret))


;;; @ field parser
;;;

(defun mime-decode-parameter-value (text charset language)
  (let ((start 0))
    (while (string-match "%[0-9A-Fa-f][0-9A-Fa-f]" text start)
      (setq text (replace-match
		  (char-to-string
		   (string-to-int (substring text
					     (1+ (match-beginning 0))
					     (match-end 0))
				  16))
		  t t text)
	    start (1+ (match-beginning 0))))
    ;; I believe that `decode-mime-charset-string' of mcs-e20.el should
    ;; be independent of the value of `enable-multibyte-characters'.
    ;; (when charset
    ;;   (setq text (decode-mime-charset-string text charset)))
    (when charset
      (with-temp-buffer
	(set-buffer-multibyte t)
	(setq text (decode-mime-charset-string text charset))))
    (when language
      (put-text-property 0 (length text) 'mime-language language text))
    text))

(defun mime-decode-parameter-encode-segment (segment)
  (if (string-match (eval-when-compile
		      (concat "^" mime-attribute-char-regexp "+$"))
		    segment)
      ;; shortcut
      segment
    ;; XXX: make too many temporary strings.
    (mapconcat
     (function
      (lambda (chr)
	(if (string-match mime-attribute-char-regexp (char-to-string chr))
	    (char-to-string chr)
	  (format "%%%02X" chr))))
     segment "")))

(defun mime-decode-parameter-plist (params)
  "Decode PARAMS as a property list of MIME parameter values.

PARAMS is a property list, which is a list of the form
\(PARAMETER-NAME1 VALUE1 PARAMETER-NAME2 VALUE2...).

This function returns an alist of the form
\((ATTRIBUTE1 . DECODED-VALUE1) (ATTRIBUTE2 . DECODED-VALUE2)...).

If parameter continuation is used, segments of values are concatenated.
If parameters contain charset information, values are decoded.
If parameters contain language information, it is set to `mime-language'
property of the decoded-value."
  ;; should signal an error?
  ;; (unless (zerop (% (length params) 2)) ...)
  (let ((len (/ (length params) 2))
        dest eparams)
    (while params
      (if (and (string-match (eval-when-compile
			       (concat "^\\(" mime-attribute-char-regexp "+\\)"
				       "\\(\\*\\([0-9]+\\)\\)?" ; continuation
				       "\\(\\*\\)?$")) ; charset/language info
			     (car params))
	       (> (match-end 0) (match-end 1)))
          (let* ((attribute (downcase
			     (substring (car params) 0 (match-end 1))))
                 (section (if (match-beginning 2)
			      (string-to-int
			       (substring (car params)
					  (match-beginning 3)(match-end 3)))
			    0))
		 ;; EPARAM := (ATTRIBUTE CHARSET LANGUAGE VALUES)
		 ;; VALUES := [1*VALUE] ; vector of (length params) elements.
                 (eparam (assoc attribute eparams)))
            (unless eparam
              (setq eparam (cons attribute
				 (list nil nil (make-vector len nil)))
                    eparams (cons eparam eparams)))
	    (setq params (cdr params))
	    ;; if parameter-name ends with "*", it is an extended-parameter.
            (if (match-beginning 4)
                (if (zerop section)
		    ;; extended-initial-parameter.
		    (if (string-match (eval-when-compile
					(concat
					 "^\\("
					 mime-charset-regexp
					 "\\)?"
					 "\\('\\("
					 mime-language-regexp
					 "\\)?'\\)"
					 "\\("
					 mime-attribute-char-regexp
					 "\\|%[0-9A-Fa-f][0-9A-Fa-f]\\)+$"))
				      (car params))
			(progn
			  ;; charset
			  (setcar (cdr eparam) ; (nthcdr 1 eparam)
				  (downcase
				   (substring (car params)
					      0 (match-beginning 2))))
			  ;; language
			  (setcar (nthcdr 2 eparam)
				  (downcase
				   (substring (car params)
					      (1+ (match-beginning 2))
					      (1- (match-end 2)))))
			  ;; text
			  (aset (nth 3 eparam) 0
				(substring (car params)
					   (match-end 2))))
		      ;; invalid parameter-value.
		      (aset (nth 3 eparam) 0
			    (mime-decode-parameter-encode-segment
			     (car params))))
		  ;; extended-other-parameter.
		  (if (string-match (eval-when-compile
				      (concat
				       "^\\("
				       mime-attribute-char-regexp
				       "\\|%[0-9A-Fa-f][0-9A-Fa-f]\\)+$"))
				    (car params))
		      (aset (nth 3 eparam) section
			    (car params))
		    ;; invalid parameter-value.
		    (aset (nth 3 eparam) section
			  (mime-decode-parameter-encode-segment
			   (car params)))))
	      ;; regular-parameter.
              (aset (nth 3 eparam) section
		    (mime-decode-parameter-encode-segment
		     (car params)))))
	;; no parameter value extensions used, or invalid attribute-name.
        (setq dest (cons (cons (downcase (car params))
			       (car (cdr params)))
			 dest)
	      params (cdr params)))
      (setq params (cdr params)))
    ;; concat and decode parameters.
    (while eparams
      (setq dest (cons (cons (car (car eparams)) ; attribute
			     (mime-decode-parameter-value
			      (mapconcat (function identity)
					 (nth 3 (car eparams)) ; values
					 "")
			      (nth 1 (car eparams)) ; charset
			      (nth 2 (car eparams)) ; language
			      ))
		       dest)
	    eparams (cdr eparams)))
    dest))

(defun mime-parse-alist-to-plist (alist)
  (let ((plist alist)
        head tail key value)
    (while alist
      (setq head (car alist)
            tail (cdr alist)
            key   (car head)
            value (cdr head))
      (setcar alist key)
      (setcar head value)
      (setcdr head tail)
      (setcdr alist head)
      (setq alist tail))
    plist))

(defun mime-decode-parameter-alist (params)
  "Decode PARAMS as an association list of MIME parameter values.
See `mime-decode-parameter-plist' for more information."
  (mime-decode-parameter-plist
   (mime-parse-alist-to-plist params)))

;;;###autoload
;; (defalias 'mime-decode-parameters 'mime-decode-parameter-alist)
(defalias 'mime-decode-parameters 'mime-decode-parameter-plist)

;;; for compatibility with flim-1_13-rfc2231 API.
(defalias 'mime-parse-parameters-from-list 'mime-decode-parameters)
(make-obsolete 'mime-parse-parameters-from-list 'mime-decode-parameters)

(defun mime-parse-parameters (tokens)
  "Parse TOKENS as MIME parameter values.
Return a property list, which is a list of the form
\(PARAMETER-NAME1 VALUE1 PARAMETER-NAME2 VALUE2...)."
  (let (params attribute)
    (while (and tokens
		(equal (car tokens) '(tspecials . ";"))
		(setq tokens (cdr tokens))
		(eq (car (car tokens)) 'mime-token)
		(progn
		  (setq attribute (cdr (car tokens)))
		  (setq tokens (cdr tokens)))
		(equal (car tokens) '(tspecials . "="))
		(setq tokens (cdr tokens))
		(memq (car (car tokens)) '(mime-token quoted-string)))
      (setq params (cons (if (eq (car (car tokens)) 'quoted-string)
			     (std11-strip-quoted-pair (cdr (car tokens)))
			   (cdr (car tokens)))
			 (cons attribute params))
	    tokens (cdr tokens)))
    (nreverse params)))


;;; @@ Content-Type
;;;

;;;###autoload
(defun mime-parse-Content-Type (field-body)
  "Parse FIELD-BODY as Content-Type field.  FIELD-BODY is a string.

Return value is

    ((type . PRIMARY-TYPE)
     (subtype. SUBTYPE)
     (ATTRIBUTE1 . VALUE1)(ATTRIBUTE2 . VALUE2) ...)

or nil.

PRIMARY-TYPE and SUBTYPE are symbols, and other elements are strings."
  (let ((tokens (mime-lexical-analyze field-body)))
    (when (eq (car (car tokens)) 'mime-token)
      (let ((primary-type (cdr (car tokens))))
	(setq tokens (cdr tokens))
	(when (and (equal (car tokens) '(tspecials . "/"))
		   (setq tokens (cdr tokens))
		   (eq (car (car tokens)) 'mime-token))
	  (make-mime-content-type
	   (intern (downcase primary-type))
	   (intern (downcase (cdr (car tokens))))
	   (mime-decode-parameters
	    (mime-parse-parameters (cdr tokens)))))))))

;;;###autoload
(defun mime-read-Content-Type ()
  "Parse field-body of Content-Type field of current-buffer.
Format of return value is same as that of `mime-parse-Content-Type'."
  (let ((field-body (std11-field-body "Content-Type")))
    (if field-body
	(mime-parse-Content-Type field-body)
      )))


;;; @@ Content-Disposition
;;;

;;;###autoload
(defun mime-parse-Content-Disposition (field-body)
  "Parse FIELD-BODY as Content-Disposition field.  FIELD-BODY is a string.

Return value is

    ((type . DISPOSITION-TYPE)
     (ATTRIBUTE1 . VALUE1)(ATTRIBUTE2 . VALUE2) ...)

or nil.

DISPOSITION-TYPE is a symbol, and other elements are strings."
  (let ((tokens (mime-lexical-analyze field-body)))
    (when (eq (car (car tokens)) 'mime-token)
      (make-mime-content-disposition
       (intern (downcase (cdr (car tokens))))
       (mime-decode-parameters
	(mime-parse-parameters (cdr tokens)))))))

;;;###autoload
(defun mime-read-Content-Disposition ()
  "Parse field-body of Content-Disposition field of current-buffer."
  (let ((field-body (std11-field-body "Content-Disposition")))
    (if field-body
	(mime-parse-Content-Disposition field-body)
      )))


;;; @@ Content-Transfer-Encoding
;;;

;;;###autoload
(defun mime-parse-Content-Transfer-Encoding (field-body)
  "Parse FIELD-BODY as Content-Transfer-Encoding field.  FIELD-BODY is a string.
Return value is a string."
  (let ((tokens (mime-lexical-analyze field-body)))
    (when (eq (car (car tokens)) 'mime-token)
      (downcase (cdr (car tokens))))))

;;;###autoload
(defun mime-read-Content-Transfer-Encoding ()
  "Parse field-body of Content-Transfer-Encoding field of current-buffer."
  (let ((field-body (std11-field-body "Content-Transfer-Encoding")))
    (if field-body
	(mime-parse-Content-Transfer-Encoding field-body)
      )))


;;; @@ Content-ID / Message-ID
;;;

;;;###autoload
(defun mime-parse-msg-id (tokens)
  "Parse TOKENS as msg-id of Content-ID or Message-ID field."
  (car (std11-parse-msg-id tokens)))

;;;###autoload
(defun mime-uri-parse-cid (string)
  "Parse STRING as cid URI."
  (mime-parse-msg-id (cons '(specials . "<")
			   (nconc
			    (cdr (cdr (std11-lexical-analyze string)))
			    '((specials . ">"))))))


;;; @ message parser
;;;

;; (defun mime-parse-multipart (entity)
;;   (with-current-buffer (mime-entity-body-buffer entity)
;;     (let* ((representation-type
;;             (mime-entity-representation-type-internal entity))
;;            (content-type (mime-entity-content-type-internal entity))
;;            (dash-boundary
;;             (concat "--"
;;                     (mime-content-type-parameter content-type "boundary")))
;;            (delimiter       (concat "\n" (regexp-quote dash-boundary)))
;;            (close-delimiter (concat delimiter "--[ \t]*$"))
;;            (rsep (concat delimiter "[ \t]*\n"))
;;            (dc-ctl
;;             (if (eq (mime-content-type-subtype content-type) 'digest)
;;                 (make-mime-content-type 'message 'rfc822)
;;               (make-mime-content-type 'text 'plain)
;;               ))
;;            (body-start (mime-entity-body-start-point entity))
;;            (body-end (mime-entity-body-end-point entity)))
;;       (save-restriction
;;         (goto-char body-end)
;;         (narrow-to-region body-start
;;                           (if (re-search-backward close-delimiter nil t)
;;                               (match-beginning 0)
;;                             body-end))
;;         (goto-char body-start)
;;         (if (re-search-forward
;;              (concat "^" (regexp-quote dash-boundary) "[ \t]*\n")
;;              nil t)
;;             (let ((cb (match-end 0))
;;                   ce ncb ret children
;;                   (node-id (mime-entity-node-id-internal entity))
;;                   (i 0))
;;               (while (re-search-forward rsep nil t)
;;                 (setq ce (match-beginning 0))
;;                 (setq ncb (match-end 0))
;;                 (save-restriction
;;                   (narrow-to-region cb ce)
;;                   (setq ret (mime-parse-message representation-type dc-ctl
;;                                                 entity (cons i node-id)))
;;                   )
;;                 (setq children (cons ret children))
;;                 (goto-char (setq cb ncb))
;;                 (setq i (1+ i))
;;                 )
;;               (setq ce (point-max))
;;               (save-restriction
;;                 (narrow-to-region cb ce)
;;                 (setq ret (mime-parse-message representation-type dc-ctl
;;                                               entity (cons i node-id)))
;;                 )
;;               (setq children (cons ret children))
;;               (mime-entity-set-children-internal entity (nreverse children))
;;               )
;;           (mime-entity-set-content-type-internal
;;            entity (make-mime-content-type 'message 'x-broken))
;;           nil)
;;         ))))

;; (defun mime-parse-encapsulated (entity)
;;   (mime-entity-set-children-internal
;;    entity
;;    (with-current-buffer (mime-entity-body-buffer entity)
;;      (save-restriction
;;        (narrow-to-region (mime-entity-body-start-point entity)
;;                          (mime-entity-body-end-point entity))
;;        (list (mime-parse-message
;;               (mime-entity-representation-type-internal entity) nil
;;               entity (cons 0 (mime-entity-node-id-internal entity))))
;;        ))))

;; (defun mime-parse-external (entity)
;;   (require 'mmexternal)
;;   (mime-entity-set-children-internal
;;    entity
;;    (with-current-buffer (mime-entity-body-buffer entity)
;;      (save-restriction
;;        (narrow-to-region (mime-entity-body-start-point entity)
;;                          (mime-entity-body-end-point entity))
;;        (list (mime-parse-message
;;               'mime-external-entity nil
;;               entity (cons 0 (mime-entity-node-id-internal entity))))
;;        ;; [tomo] Should we unify with `mime-parse-encapsulated'?
;;        ))))

(defun mime-parse-message (representation-type &optional default-ctl 
					       parent node-id)
  (let ((header-start (point-min))
	header-end
	body-start
	(body-end (point-max))
	content-type)
    (goto-char header-start)
    (if (re-search-forward "^$" nil t)
	(setq header-end (match-end 0)
	      body-start (if (= header-end body-end)
			     body-end
			   (1+ header-end)))
      (setq header-end (point-min)
	    body-start (point-min)))
    (save-restriction
      (narrow-to-region header-start header-end)
      (setq content-type (or (let ((str (std11-fetch-field "Content-Type")))
			       (if str
				   (mime-parse-Content-Type str)
				 ))
			     default-ctl))
      )
    (luna-make-entity representation-type
		      :location (current-buffer)
		      :content-type content-type
		      :parent parent
		      :node-id node-id
		      :buffer (current-buffer)
		      :header-start header-start
		      :header-end header-end
		      :body-start body-start
		      :body-end body-end)
    ))


;;; @ for buffer
;;;

;;;###autoload
(defun mime-parse-buffer (&optional buffer representation-type)
  "Parse BUFFER as a MIME message.
If buffer is omitted, it parses current-buffer."
  (save-excursion
    (if buffer (set-buffer buffer))
    (mime-parse-message (or representation-type
			    'mime-buffer-entity) nil)))


;;; @ end
;;;

(provide 'mime-parse)

;;; mime-parse.el ends here
