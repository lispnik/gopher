;;;; render.lisp -- DOCUMENTs as plain text, for terminals and debugging.

(in-package #:gopher)

(defun gopher-type-tag (line)
  (case (line-item-kind line)
    (:menu "DIR") (:text "TXT") (:search "SRCH") (:binary "BIN") (:image "IMG")
    (:sound "SND") (:video "VID") (:document "DOC") (:html "HTML") (:telnet "TEL")
    (:mirror "MIR") (:cso "CSO") (:calendar "CAL") (t "???")))

(defun render-document (document &key (stream *standard-output*) (show-urls t))
  "Write DOCUMENT to STREAM as text.  Links are numbered from 1.  Returns the
link URLs as a vector, so link N is (aref result (1- N))."
  (let ((links (make-array 0 :adjustable t :fill-pointer 0))
        (menu (eq (document-kind document) :menu)))
    (loop for line across (document-lines document)
          do (flet ((link (prefix)
                      (vector-push-extend (line-url line) links)
                      (format stream "~&[~D]~A ~A~:[~; <~A>~]~%" (length links) prefix (line-text line)
                              (and show-urls (not menu)) (line-url line))))
               (ecase (line-kind line)
                 (:text (format stream "~&~:[~;      ~]~A~%" menu (line-text line)))
                 (:error (format stream "~&!! ~A~%" (line-text line)))
                 (:heading (format stream "~&~A ~A~%"
                                   (make-string (or (line-level line) 1) :initial-element #\#)
                                   (line-text line)))
                 (:list-item (format stream "~&  * ~A~%" (line-text line)))
                 (:quote (format stream "~&  > ~A~%" (line-text line)))
                 (:preformatted (format stream "~&~A~%" (line-text line)))
                 (:input-prompt (link " ?"))
                 (:link (link (if menu (format nil " (~A)" (gopher-type-tag line)) ""))))))
    links))

(defun render-response (response &key (stream *standard-output*) (show-urls t))
  "Render RESPONSE: its document if it has one, its text for other text, or a
one-line summary for binary bodies and non-success statuses.  Returns the
link vector (empty if there is no document)."
  (let ((doc (response-document response)))
    (cond (doc (render-document doc :stream stream :show-urls show-urls))
          ((not (response-success-p response))
           (format stream "~&~A~@[ (~D)~]: ~A~%" (response-status response)
                   (response-status-code response) (response-meta response))
           #())
          (t (format stream "~&[~A, ~D bytes]~%" (response-mime-type response)
                     (response-bytes-read response))
             #()))))
