;;; slirm.el -- Systematic Literature Review Mode for Emacs.
;;; Commentary:
;;; Code:

(require 'bibtex)

;;; BibTeX utility functions for moving point from entry to entry and
;;; to access fields conveniently.
(defconst slirm--next 're-search-forward)
(defconst slirm--prev 're-search-backward)

(defun slirm--bibtex-move-point-to-entry (direction)
  "Move point to the next entry in DIRECTION, which is one of slirm--{next, prev}."
  (slirm--with-bibtex-buffer
    (when (funcall direction "^@[a-zA-Z0-9]+{" nil t)
      (goto-char (match-beginning 0)))))

(defun slirm--bibtex-parse-next ()
  "Convenience function to parse next entry."
  (slirm--with-bibtex-buffer
    (slirm--bibtex-move-point-to-entry slirm--next)
    (bibtex-parse-entry t)))

(defun slirm--bibtex-parse-prev ()
  "Convenience fuction to parse previous entry."
  ;; Gotta move up twice.
  (slirm--with-bibtex-buffer
    (slirm--bibtex-move-point-to-entry slirm--prev)
    (slirm--bibtex-move-point-to-entry slirm--prev)
    (bibtex-parse-entry t))
  )

(defun slirm--bibtex-reparse ()
  "Re-parse an entry, useful after modifications and so on."
  (slirm--with-bibtex-buffer
    (slirm--bibtex-move-point-to-entry slirm--prev)
    (bibtex-parse-entry t))
  )

(defun slirm--bibtex-move-point-to-field (field)
  "Move point to start of FIELD's text."
  (when (re-search-backward (format "\s*%s\s*=[\s\t]*{" field) nil t)
    (goto-char (match-end 0))))

(defun slirm--bibtex-get-field (field entry)
  "Nil if FIELD is not present in ENTRY, otherwise the associated value."
  (let ((val (assoc field entry)))
    (if val
	(cdr val)
      nil)))

(defun slirm--bibtex-add-field (field)
  "Add a field FIELD to the entry."
  (bibtex-make-field field t 'nil 'nil))

(defun slirm--bibtex-maybe-add-field (field entry)
  "Add FIELD to ENTRY if not already present."
  (when (not (slirm--bibtex-get-field field entry))
    (slirm--add-field field)
    t))

(defun slirm--bibtex-write-to-field (field content)
  "Fill a FIELD with CONTENT."
  (slirm--bibtex-move-point-to-field field)
  (insert content))

(defun slirm--bibtex-maybe-write-to-field (field entry content)
  "Write to FIELD if ENTRY does not contain it.  CONTENT is what is written."
  (when (slirm--bibtex-maybe-add-field field entry)
    (slirm--bibtex-write-to-field field content)))

(defconst slirm--review "review" "The review field name.")
(defconst slirm--accept "accepted")
(defconst slirm--reject "rejected")
(defconst slirm--abstract "abstract" "The abstract field name.")
(defconst slirm--full-text-url "fullTextUrl" "The fullTextUrl field name.")

(defun slirm--make-user-annotation (annotation)
  "Make a string of the form \"user-login-name: ANNOTATION\"."
  (format "%s: %s," user-login-name annotation))

(defun slirm--first-match (regex)
  "Return the first string matching REGEX in the entire buffer."
  (goto-char (point-min))
  (when (re-search-forward regex nil t)
    (match-string 0)))

;;; ACM utility functions to download full-text and abstract.
(defun slirm--acm-get-full-text-link ()
  "Return the link to the full-text from the current buffer containing an ACM website."
  (slirm--first-match "ft_gateway\.cfm\\?id=[0-9]+&ftid=[0-9]+&dwn=[0-9]+&CFID=[0-9]+&CFTOKEN=[0-9]+"))

(defun slirm--acm-get-abstract-link ()
  "Return the link to the abstract from the current buffer containing an ACM website."
  (slirm--first-match "tab_abstract\.cfm\\?id=[0-9]+&usebody=tabbody&cfid=[0-9]+&cftoken=[0-9]+"))

(defun slirm--acm-make-dl-link (link)
  "Build ACM link address from LINK."
  (format "http://dl.acm.org/%s" link))

(defun slirm--acm-get-links (acm-url)
  "Retrieves the links to the abstract and the full-text by retrieving ACM-URL."
  (with-current-buffer (url-retrieve-synchronously acm-url)
    (mapcar 'slirm--acm-make-dl-link
	    (list (slirm--acm-get-abstract-link)
		  (slirm--acm-get-full-text-link)))))

(defun slirm--acm-get-abstract (url)
  "Download and format abstract text from URL."
  (with-current-buffer (url-retrieve-synchronously url)
    (replace-regexp-in-string "<\/?[a-zA-Z]+>" "" (slirm--first-match "<p>.*</p>"))))

(defun slirm--get-base-url (url)
  "Return the base url of URL."
  (string-match "[a-zA-Z0-0+\\.-]+\\.[a-zA-Z]+" url)
  (let ((es (reverse (split-string (match-string 0 url) "\\."))))
    (format "%s.%s" (car (cdr es)) (car es))))

(defconst slirm--get-links-map
  (list
   '("acm.org" slirm--acm-get-links)))

(defconst slirm--get-abstract-map
  (list
   '("acm.org" slirm--acm-get-abstract)))

(defun slirm--lookup (map key)
  "Perform lookup in MAP for KEY."
  (car (cdr (assoc key map))))

(defun slirm--get-links (url)
  "Get links from URL."
  (let ((getter (slirm--lookup slirm--get-links-map (slirm--get-base-url url))))
    (funcall getter url)))

(defun slirm--get-abstract (url)
  "Get abstract from URL."
  (let ((getter (slirm--lookup slirm--get-abstract-map (slirm--get-base-url url))))
    (funcall getter url)))

(defun slirm--update-abstract-fullTextUrl (entry)
  "Update abstract and fullTextURL fields if they are empty in ENTRY."
  (when (not (and ;; Any of the two fields is empty.
	      (slirm--bibtex-get-field slirm--abstract entry)
	      (slirm--bibtex-get-field slirm--full-text-url entry)))
    (let* ((url (slirm--bibtex-get-field "url" entry))
	   (urls (slirm--get-links url))) ;; Download from the article's website.
      (slirm--bibtex-maybe-write-to-field slirm--abstract entry (slirm--get-abstract (car urls)))
      (slirm--bibtex-maybe-write-to-field slirm--full-text-url entry (car (cdr urls))))))

(defun slirm-update-abstract-fullTextUrl ()
  "Update abstract and fullTextURL fields if they are empty."
  (interactive)
  (slirm--update-abstract-fullTextUrl (slirm--bibtex-reparse))
)

(defun slirm--mark-reviewed (entry review)
  "Mark ENTRY as reviewed with REVIEW if not yet reviewed."
  (slirm--bibtex-maybe-add-field slirm--review entry)
  (let* ((entry (slirm--bibtex-reparse))
	 (contents (slirm--bibtex-get-field slirm--review entry)))
    (if (and contents (string-match-p (regexp-quote user-login-name) contents))
	(message "Already reviewed, nothing to do.")
      (slirm--bibtex-write-to-field slirm--review (slirm--make-user-annotation review))
      (message (format "Marked %s as %s." (slirm--bibtex-get-field "=key=" entry) review)))))

(defun slirm-accept ()
  "Mark current entry as accepted."
  (interactive)
  (slirm--mark-reviewed (slirm--bibtex-reparse) slirm--accept))

(defun slirm-reject ()
  "Mark current entry as rejected."
  (interactive)
  (slirm--mark-reviewed (slirm--bibtex-reparse) slirm--reject))

(defun slirm--clear ()
  "Clear current slirm buffer."
  (delete-region (point-min) (point-max)))

(defun slirm--show (entry)
  "Show ENTRY in the review buffer."
  (slirm--clear)
  (goto-char (point-min))
  (insert (slirm--bibtex-get-field "title" entry))
  (insert "\n")
  (insert "\n")
  (insert (string-join (slirm--bibtex-get-field "author" entry)) ", "))

(defun slirm--update-and-show (entry)
  "Show ENTRY in the review buffer after update."
  (slirm--show entry)
  ;; TODO: Re-enable downloading and handle missing internet connection
  ;; (slirm--show
  ;;  (slirm--with-bibtex-buffer
  ;;    (slirm--update-abstract-fullTextUrl entry)))
  )

(defun slirm-show-next ()
  "Show the next entry in the review buffer."
  (interactive)
  (slirm--update-and-show
   (slirm--with-bibtex-buffer
     (slirm--bibtex-parse-next))))

(defun slirm-show-prev ()
  "Show the previous entry in the review buffer."
  (interactive)
  (slirm--update-and-show (slirm--bibtex-parse-prev)))

(defvar slirm-mode-hook nil)
(defvar-local slirm--bibtex-file nil)
(defvar-local slirm--point 0)

(defun slirm--bibtex-buffer ()
  "Return the buffer containing the BibTeX file."
  (find-file slirm--bibtex-file))

(defun slirm-start ()
  "Start a systematic literature review of the BibTeX file in the current buffer."
  (interactive)
  (let ((file (buffer-file-name)))
    (pop-to-buffer (get-buffer-create (format "*Review of %s*" file)))
    (setq slirm--bibtex-file file)
    (slirm-mode)))

(defmacro slirm--with-current-buffer (buffer &rest body)
  "Like (with-current-buffer BUFFER (save-excursion &BODY)) but save the point."
  (declare (indent 1))
  (let ((outer (cl-gensym "outer-buffer"))
	(body-res (cl-gensym "body-res"))) ;; This is the variable name
    `(let ((,outer (current-buffer))) ;; Store current buffer, so we can switch to it to save point.) (with-current-buffer ,buffer
	  (save-excursion
	    (goto-char slirm--point)
	    (let ((,body-res  (progn ,@body)))
	      (with-current-buffer ,outer
		(setq slirm--point))
	      ,body-res)))))

(defmacro slirm--with-bibtex-buffer (&rest body)
  "Perform BODY in slirm--bibtex-buffer."
  (declare (indent 0))
  `(slirm--with-current-buffer (slirm--bibtex-buffer)
			       ,@body))

(define-derived-mode slirm-mode special-mode
  "Systematic Literature Review Mode."
  (slirm-show-next))

(provide 'slirm-start)
(provide 'slirm-show-next)
(provide 'slirm-show-prev)
(provide 'slirm-accept)
(provide 'slirm-reject)
;;; slirm.el ends here
