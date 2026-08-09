;;; PoW driver for scm/shavar.scm. See tests/pow.sh.
;;;
;;; Reads the vector file named on the command line and writes one
;;; `id <TAB> met|unmet|invalid` line per vector. Marshalling only: every
;;; decision comes from pow-check.
;;;
;;; scm/shavar.scm runs its CLI on load unless SHAVAR_LIB is set in the
;;; environment, which tests/pow.sh does before invoking this file.

(import (scheme base)
        (scheme file)
        (scheme load)
        (scheme read)
        (scheme write)
        (scheme process-context))

;; scm/shavar.scm is loaded, not imported: it is a program with a modulino
;; guard rather than a library, exactly as pl/shavar.pl and sh/shavar.sh are.
;; SHAVAR_LIB suppresses its CLI; tests/pow.sh sets it.
(load (string-append
       (or (get-environment-variable "SHAVAR_REPO") ".")
       "/scm/shavar.scm"))

(define (split-tabs s)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s))
           (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) #\tab)
           (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (hex-value ch)
  (let ((c (char->integer ch)))
    (cond ((and (>= c 48) (<= c 57)) (- c 48))
          ((and (>= c 97) (<= c 102)) (- c 87))
          ((and (>= c 65) (<= c 70)) (- c 55))
          (else (error "bad hex digit" ch)))))

(define (hex->bv s)
  (let* ((n (quotient (string-length s) 2))
         (bv (make-bytevector n 0)))
    (let loop ((i 0))
      (if (= i n)
          bv
          (begin
            (bytevector-u8-set!
             bv i (+ (* 16 (hex-value (string-ref s (* 2 i))))
                     (hex-value (string-ref s (+ (* 2 i) 1)))))
            (loop (+ i 1)))))))

(define (hex->int s)
  (let loop ((i 0) (v 0))
    (if (= i (string-length s))
        v
        (loop (+ i 1) (+ (* v 16) (hex-value (string-ref s i)))))))

(define (run path)
  (call-with-input-file path
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (if (eof-object? line)
              #t
              (begin
                (if (and (> (string-length line) 0)
                         (not (char=? (string-ref line 0) #\#)))
                    (let ((f (split-tabs line)))
                      (if (>= (length f) 3)
                          (let* ((id (list-ref f 0))
                                 (digest (hex->bv (list-ref f 1)))
                                 (nbits (hex->int (list-ref f 2)))
                                 (verdict
                                  (guard (e (#t "invalid"))
                                    (if (pow-check digest nbits)
                                        "met"
                                        "unmet"))))
                            (display id) (display "\t")
                            (display verdict) (newline)))))
                (loop)))))))
  #t)

;; A canary, run OUTSIDE the guard above. The guard turns an error from
;; `pow-check` into the verdict "invalid", which is right for a malformed
;; nBits and catastrophically wrong for a missing procedure: without this
;; probe, a driver that failed to load the implementation would print
;; "invalid" for all eighteen vectors and look like a self-consistent opinion
;; rather than a broken driver. Any error here propagates and kills the
;; driver, which tests/pow.sh reports as BROKEN.
(if (not (bytevector? (pow-target #x1d00ffff)))
    (error "pow-target did not return a bytevector"))

(let ((args (cdr (command-line))))
  (if (not (= (length args) 1))
      (begin (display "usage: driver.scm VECTORS.tsv\n" (current-error-port))
             (exit 2))
      (begin (run (car args)) (exit 0))))
