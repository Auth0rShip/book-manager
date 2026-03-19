;; Load Quicklisp
(load "~/quicklisp/setup.lisp")

;; Load dependencies
;; Added in improved version: :cl-dbi :dbd-sqlite3 :bordeaux-threads
(ql:quickload '(:hunchentoot :cl-json :dexador :cl-ppcre
                :cl-dbi :dbd-sqlite3 :bordeaux-threads)
              :silent t)

;; Load the application
(load "book-manager-web.lisp")

;; Start the server
(in-package :book-manager-web)
(start-server)

;; Keep SBCL running (press Ctrl+C to stop)
(handler-case
    (loop (sleep 1))
  (sb-sys:interactive-interrupt ()
    (stop-server)
    (sb-ext:exit)))
