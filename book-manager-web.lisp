;;;; book-manager-web.lisp
;;;; Book Manager Web Edition - Hunchentoot + SQLite + REST API
;;;;
;;;; Improvements:
;;;;   1. SQLite backend — replaced in-memory storage with per-record DB operations
;;;;   2. Thread safety — write operations protected with bordeaux-threads locks
;;;;   3. RESTful routing — PUT/DELETE sent to /api/books/:isbn
;;;;   4. Separate frontend HTML — index.html served from an external file
;;;;   5. External API timeouts — dexador calls use :connect-timeout / :read-timeout
;;;;   6. UI shutdown — POST /api/shutdown to gracefully stop the server
;;;;
;;;; Dependencies:
;;;;   (ql:quickload '(:hunchentoot :cl-json :dexador :cl-ppcre
;;;;                   :cl-dbi :dbd-sqlite3 :bordeaux-threads))
;;;;
;;;; Usage:
;;;;   (load "book-manager-web.lisp")
;;;;   (in-package :book-manager-web)
;;;;   (start-server)          ; starts on http://localhost:8080
;;;;   (stop-server)           ; shuts down

;;; ============================================================
;;; Package Definition
;;; ============================================================
(defpackage :book-manager-web
  (:use :cl :hunchentoot)
  (:export :start-server :stop-server))

(in-package :book-manager-web)

;;; ============================================================
;;; Global Variables
;;; ============================================================

(defvar *server* nil
  "Hunchentoot server instance.")
(defvar *db* nil
  "cl-dbi database connection.")
(defvar *db-lock* (bt:make-lock "db-lock")
  "Lock for DB write operations.")
(defvar *db-file* "library.db"
  "SQLite database file path.")
(defvar *html-file* "index.html"
  "Frontend HTML file path.")

;; Timeout (seconds) for external API calls
(defvar *api-connect-timeout* 5)
(defvar *api-read-timeout* 10)

;;; ============================================================
;;; ISBN Validation
;;; ============================================================

(defun normalize-isbn (isbn-str)
  "Strip hyphens and whitespace, keeping only digits."
  (coerce (remove-if-not #'digit-char-p isbn-str) 'string))

(defun validate-isbn-13 (isbn-str)
  "Verify the ISBN-13 check digit."
  (let ((digits (remove-if-not #'digit-char-p isbn-str)))
    (when (= (length digits) 13)
      (let ((sum (loop for ch across digits
                       for i from 0
                       sum (* (digit-char-p ch) (if (evenp i) 1 3)))))
        (zerop (mod sum 10))))))

;;; ============================================================
;;; Title Auto-Fetch
;;; Priority: NDL (Japanese books) -> Google Books -> Open Library
;;;
;;; Improvement: All external API calls have timeouts configured so
;;;              a single unresponsive API does not block the whole process.
;;; ============================================================

(defun fetch-title-from-ndl (isbn)
  "Fetch a book title by ISBN from the National Diet Library Search API."
  (handler-case
      (let* ((url (format nil
                          "https://iss.ndl.go.jp/api/openurl?isbn=~A&mediatype=1"
                          isbn))
             (response (dex:get url
                                :connect-timeout *api-connect-timeout*
                                :read-timeout *api-read-timeout*))
             (start (search "<dc:title>" response))
             (end   (when start (search "</dc:title>" response :start2 start))))
        (when (and start end)
          (let ((title (subseq response (+ start (length "<dc:title>")) end)))
            (when (> (length title) 0) title))))
    (error () nil)))

(defun fetch-title-from-google-books (isbn)
  "Fetch a book title by ISBN from the Google Books API."
  (handler-case
      (let* ((url (format nil
                          "https://www.googleapis.com/books/v1/volumes?q=isbn:~A"
                          isbn))
             (response (dex:get url
                                :headers '(("Accept" . "application/json"))
                                :connect-timeout *api-connect-timeout*
                                :read-timeout *api-read-timeout*))
             (json-data (json:decode-json-from-string response))
             (total (cdr (assoc :total-items json-data))))
        (when (and total (> total 0))
          (let* ((items      (cdr (assoc :items json-data)))
                 (first-item (first items))
                 (vol-info   (cdr (assoc :volume-info first-item))))
            (cdr (assoc :title vol-info)))))
    (error () nil)))

(defun fetch-title-from-open-library (isbn)
  "Fetch a book title by ISBN from the Open Library API."
  (handler-case
      (let* ((url (format nil
                          "https://openlibrary.org/api/books?bibkeys=ISBN:~A&format=json&jscmd=data"
                          isbn))
             (response (dex:get url
                                :headers '(("Accept" . "application/json"))
                                :connect-timeout *api-connect-timeout*
                                :read-timeout *api-read-timeout*))
             (json-data (json:decode-json-from-string response))
             (book-data (cdar json-data)))
        (when book-data
          (cdr (assoc :title book-data))))
    (error () nil)))

(defun fetch-title (isbn)
  "Fetch a book title by ISBN, trying three APIs as fallbacks."
  (or (fetch-title-from-ndl isbn)
      (fetch-title-from-google-books isbn)
      (fetch-title-from-open-library isbn)))

;;; ============================================================
;;; SQLite Database Operations
;;;
;;; Improvement: Replaced bulk JSON read/write with per-record SQLite
;;;              CRUD operations. Writes are thread-safe via bt:with-lock-held.
;;; ============================================================

(defun ensure-integer (val &optional (default 3))
  "Coerce a value to an integer. Handles strings, numbers, and nil."
  (cond
    ((null val) default)
    ((integerp val) val)
    ((numberp val) (round val))
    ((stringp val)
     (or (parse-integer val :junk-allowed t) default))
    (t default)))

(defun init-db ()
  "Open the database connection and create the table if it does not exist."
  (setf *db* (dbi:connect :sqlite3 :database-name *db-file*))
  (dbi:do-sql *db*
    "CREATE TABLE IF NOT EXISTS books (
       isbn        TEXT PRIMARY KEY,
       title       TEXT NOT NULL,
       read_status TEXT NOT NULL DEFAULT 'unread',
       priority    INTEGER NOT NULL DEFAULT 3,
       genre       TEXT NOT NULL DEFAULT 'Uncategorized'
     )")
  (format t "Database initialized: ~A~%" *db-file*))

(defun close-db ()
  "Close the database connection."
  (when *db*
    (dbi:disconnect *db*)
    (setf *db* nil)))

(defun row-to-alist (row)
  "Convert a dbi:fetch result (plist) to an alist suitable for JSON output."
  (when row
    (list (cons "isbn"        (getf row :|isbn|))
          (cons "title"       (getf row :|title|))
          (cons "read_status" (getf row :|read_status|))
          (cons "priority"    (getf row :|priority|))
          (cons "genre"       (getf row :|genre|)))))

(defun db-find-book (isbn)
  "Find a single book by ISBN. Returns an alist or nil."
  (let* ((query (dbi:prepare *db*
                  "SELECT isbn, title, read_status, priority, genre
                   FROM books WHERE isbn = ?"))
         (result (dbi:execute query (list isbn)))
         (row (dbi:fetch result)))
    (row-to-alist row)))

(defun db-list-books (&key q genre status)
  "List books with optional search and filter parameters.
   Filtering is done in SQL via LIKE, so no in-memory filtering is needed."
  (let ((conditions '())
        (params '()))
    (when (and q (> (length q) 0))
      (push "(title LIKE ? OR isbn LIKE ?)" conditions)
      (let ((pattern (format nil "%~A%" q)))
        (push pattern params)
        (push pattern params)))
    (when (and genre (> (length genre) 0))
      (push "genre = ?" conditions)
      (push genre params))
    (when (and status (> (length status) 0))
      (push "read_status = ?" conditions)
      (push status params))
    (let* ((where (if conditions
                      (format nil " WHERE ~{~A~^ AND ~}" (reverse conditions))
                      ""))
           (sql (format nil
                        "SELECT isbn, title, read_status, priority, genre
                         FROM books~A ORDER BY priority ASC, title ASC"
                        where))
           (query (dbi:prepare *db* sql))
           (result (dbi:execute query (reverse params)))
           (rows '()))
      (loop for row = (dbi:fetch result)
            while row
            do (push (row-to-alist row) rows))
      (nreverse rows))))

(defun db-insert-book (isbn title &key (read-status "unread") (priority 3) (genre "Uncategorized"))
  "Insert a single book. Thread-safe."
  (bt:with-lock-held (*db-lock*)
    (let ((query (dbi:prepare *db*
                   "INSERT INTO books (isbn, title, read_status, priority, genre)
                    VALUES (?, ?, ?, ?, ?)")))
      (dbi:execute query (list isbn title read-status
                               (ensure-integer priority) genre)))))

(defun db-update-book (isbn &key title read-status priority genre)
  "Update a single book. Only non-nil fields are modified. Thread-safe."
  (bt:with-lock-held (*db-lock*)
    (let ((sets '())
          (params '()))
      (when title
        (push "title = ?" sets)
        (push title params))
      (when read-status
        (push "read_status = ?" sets)
        (push read-status params))
      (when priority
        (push "priority = ?" sets)
        (push (ensure-integer priority) params))
      (when genre
        (push "genre = ?" sets)
        (push genre params))
      (when sets
        (let* ((sql (format nil "UPDATE books SET ~{~A~^, ~} WHERE isbn = ?"
                            (reverse sets)))
               (query (dbi:prepare *db* sql)))
          (dbi:execute query (append (reverse params) (list isbn))))))))

(defun db-delete-book (isbn)
  "Delete a single book. Thread-safe."
  (bt:with-lock-held (*db-lock*)
    (let ((query (dbi:prepare *db* "DELETE FROM books WHERE isbn = ?")))
      (dbi:execute query (list isbn)))))

(defun db-list-genres ()
  "Return a list of all distinct genres currently registered."
  (let* ((query (dbi:prepare *db*
                  "SELECT DISTINCT genre FROM books ORDER BY genre"))
         (result (dbi:execute query nil))
         (genres '()))
    (loop for row = (dbi:fetch result)
          while row
          do (push (getf row :|genre|) genres))
    (nreverse genres)))

;;; ============================================================
;;; JSON Response Helpers
;;; ============================================================

(defun json-response (data &optional (status 200))
  "Return a JSON response with Content-Type and CORS headers set."
  (setf (return-code*) status)
  (setf (content-type*) "application/json; charset=utf-8")
  (setf (header-out "Access-Control-Allow-Origin") "*")
  (setf (header-out "Access-Control-Allow-Methods") "GET, POST, PUT, DELETE, OPTIONS")
  (setf (header-out "Access-Control-Allow-Headers") "Content-Type")
  (json:encode-json-to-string data))

(defun error-response (message &optional (status 400))
  (json-response (list (cons "error" message)) status))

(defun parse-request-body ()
  "Parse the request body as JSON."
  (handler-case
      (let ((body (raw-post-data :force-text t)))
        (when (and body (> (length body) 0))
          (json:decode-json-from-string body)))
    (error () nil)))

(defun body-field (body &rest keys)
  "Look up a value in a body alist, trying multiple keys.
   This handles cl-json keyword conversion variations."
  (loop for key in keys
        for val = (cdr (assoc key body))
        when val return val))

;;; ============================================================
;;; RESTful Routing
;;;
;;; Improvement: Replaced /api/books/edit?isbn=... and
;;;              /api/books/delete?isbn=... with RESTful PUT/DELETE
;;;              to /api/books/:isbn.
;;;
;;; Since Hunchentoot's define-easy-handler does not support path
;;; parameter extraction, a custom dispatcher is used to manually
;;; extract the ISBN from the URI.
;;; ============================================================

(defun extract-isbn-from-uri (uri prefix)
  "Remove the prefix from a URI string and return the remainder as an ISBN.
   Example: /api/books/9784873119038 -> 9784873119038"
  (let ((isbn (subseq uri (length prefix))))
    (when (> (length isbn) 0)
      (hunchentoot:url-decode isbn))))

(defun handle-books-collection ()
  "GET  /api/books — list all books
   POST /api/books — add a new book"
  (let ((method (request-method*)))
    (cond
      ((eq method :OPTIONS)
       (json-response "ok"))
      ;; ---- GET: list books ----
      ((eq method :GET)
       (let ((q      (parameter "q"))
             (genre  (parameter "genre"))
             (status (parameter "status")))
         (json-response (db-list-books :q q :genre genre :status status))))
      ;; ---- POST: add a book ----
      ((eq method :POST)
       (let* ((body     (parse-request-body))
              (isbn     (normalize-isbn (or (body-field body :isbn) "")))
              (title    (body-field body :title))
              (genre    (or (body-field body :genre) "Uncategorized"))
              (priority (or (body-field body :priority) 3)))
         (cond
           ((= (length isbn) 0)
            (error-response "ISBN is required"))
           ((db-find-book isbn)
            (error-response "This ISBN is already registered" 409))
           ((not (validate-isbn-13 isbn))
            (error-response "Invalid ISBN-13"))
           (t
            (let ((resolved-title (if (or (null title) (string= title ""))
                                      (or (fetch-title isbn) "(Title not found)")
                                      title)))
              (db-insert-book isbn resolved-title
                              :genre genre :priority priority)
              (json-response (db-find-book isbn) 201))))))
      (t (error-response "Method not allowed" 405)))))

(defun handle-books-single (isbn)
  "GET    /api/books/:isbn — retrieve a single book
   PUT    /api/books/:isbn — update a single book
   DELETE /api/books/:isbn — delete a single book"
  (let ((method (request-method*)))
    (cond
      ((eq method :OPTIONS)
       (json-response "ok"))
      ;; ---- GET: retrieve one book ----
      ((eq method :GET)
       (let ((book (db-find-book isbn)))
         (if book
             (json-response book)
             (error-response "ISBN not found" 404))))
      ;; ---- PUT: update one book ----
      ((eq method :PUT)
       (if (null (db-find-book isbn))
           (error-response "ISBN not found" 404)
           (let* ((body (parse-request-body))
                  (new-title    (body-field body :title))
                  (new-status   (body-field body :read--status :read-status))
                  (new-priority (body-field body :priority))
                  (new-genre    (body-field body :genre)))
             (db-update-book isbn
                             :title new-title
                             :read-status new-status
                             :priority new-priority
                             :genre new-genre)
             (json-response (db-find-book isbn)))))
      ;; ---- DELETE: delete one book ----
      ((eq method :DELETE)
       (if (null (db-find-book isbn))
           (error-response "ISBN not found" 404)
           (progn
             (db-delete-book isbn)
             (json-response (list (cons "deleted" isbn))))))
      (t (error-response "Method not allowed" 405)))))

(defun dispatch-books (request)
  "Dispatcher for the /api/books URI prefix.
   /api/books     -> collection operations (GET list / POST add)
   /api/books/xxx -> individual operations (GET / PUT / DELETE)"
  (let ((uri (request-uri request)))
    ;; Strip query string if present, keeping only the path
    (let ((path (first (cl-ppcre:split "\\?" uri))))
      (cond
        ;; Exact match: /api/books
        ((string= path "/api/books")
         #'handle-books-collection)
        ;; Prefix match: /api/books/xxxxx
        ((and (> (length path) (length "/api/books/"))
              (string= (subseq path 0 (length "/api/books/")) "/api/books/"))
         (let ((isbn (extract-isbn-from-uri path "/api/books/")))
           (lambda ()
             (handle-books-single isbn))))
        (t nil)))))

;; --- GET /api/genres ---
(define-easy-handler (api-genres :uri "/api/genres") ()
  (when (eq (request-method*) :OPTIONS)
    (return-from api-genres (json-response "ok")))
  (json-response (db-list-genres)))

;; --- POST /api/import ---
(define-easy-handler (api-import :uri "/api/import" :default-request-type :post) ()
  (when (eq (request-method*) :OPTIONS)
    (return-from api-import (json-response "ok")))
  (unless (eq (request-method*) :POST)
    (return-from api-import (error-response "Method not allowed" 405)))
  (let* ((body  (parse-request-body))
         (isbns (body-field body :isbns))
         (added 0)
         (skipped 0)
         (books '()))
    (dolist (raw-isbn isbns)
      (let ((isbn (normalize-isbn raw-isbn)))
        (cond
          ((db-find-book isbn)
           (incf skipped))
          ((not (validate-isbn-13 isbn))
           (incf skipped))
          (t
           (let ((title (or (fetch-title isbn) "(Title not found)")))
             (db-insert-book isbn title)
             (push (db-find-book isbn) books)
             (incf added))))))
    (json-response (list (cons "added"   added)
                         (cons "skipped" skipped)
                         (cons "books"   (reverse books))))))

;;; ============================================================
;;; Shutdown Endpoint
;;;
;;; POST /api/shutdown — gracefully stop the server and exit.
;;; The response is sent first, then a background thread performs
;;; the actual shutdown after a short delay so the HTTP response
;;; can be flushed to the client.
;;; ============================================================

(define-easy-handler (api-shutdown :uri "/api/shutdown" :default-request-type :post) ()
  (when (eq (request-method*) :OPTIONS)
    (return-from api-shutdown (json-response "ok")))
  (unless (eq (request-method*) :POST)
    (return-from api-shutdown (error-response "Method not allowed" 405)))
  ;; Schedule shutdown in a background thread so the response can be sent first
  (bt:make-thread
   (lambda ()
     (sleep 0.5)
     (format t "~%Shutdown requested via API. Stopping server...~%")
     (stop-server)
     ;; Exit the Lisp process (works on SBCL; other implementations
     ;; may need a different call)
     #+sbcl (sb-ext:exit)
     #-sbcl (format t "Server stopped. Please terminate the process manually.~%"))
   :name "shutdown-thread")
  (json-response (list (cons "status" "shutting down"))))

;;; ============================================================
;;; Frontend Serving
;;;
;;; Improvement: Replaced the large inline HTML string literal with
;;;              external file loading. index.html can now be edited
;;;              and debugged independently.
;;; ============================================================

(defun read-file-to-string (path)
  "Read an entire file into a string."
  (with-open-file (s path :direction :input
                          :external-format :utf-8)
    (let ((content (make-string (file-length s))))
      (read-sequence content s)
      content)))

(define-easy-handler (root :uri "/") ()
  (setf (content-type*) "text/html; charset=utf-8")
  (if (probe-file *html-file*)
      (read-file-to-string *html-file*)
      (format nil "<html><body><h1>Error</h1><p>~A not found.</p></body></html>"
              *html-file*)))

;;; ============================================================
;;; Server Start / Stop
;;; ============================================================

(defun start-server (&optional (port 8080))
  "Start the Hunchentoot server on the given port."
  (when *server*
    (stop-server))
  ;; Initialize the database
  (init-db)
  ;; Set up the dispatch table with our custom dispatcher.
  ;; dispatch-books handles /api/books and below;
  ;; dispatch-easy-handlers handles everything else
  ;; (/, /api/genres, /api/import, /api/shutdown).
  (setf *dispatch-table*
        (list #'dispatch-books
              #'dispatch-easy-handlers))
  ;; Start the server
  (setf *server* (make-instance 'easy-acceptor :port port))
  (start *server*)
  (format t "~%Server started: http://localhost:~A~%" port)
  (format t "To stop: (book-manager-web:stop-server)~%"))

(defun stop-server ()
  "Stop the server and close the database connection."
  (when *server*
    (stop *server*)
    (setf *server* nil))
  (close-db)
  (format t "Server stopped.~%"))
