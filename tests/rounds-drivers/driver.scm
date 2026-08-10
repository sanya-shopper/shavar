;;; Rounds-contract driver for scm/shavar.scm. See tests/rounds.sh.
(import (scheme base) (scheme file) (scheme load) (scheme read)
        (scheme write) (scheme process-context))
(load (string-append (or (get-environment-variable "SHAVAR_REPO") ".")
                     "/scm/shavar.scm"))
;; Canary outside the guard below: a driver that failed to load the
;; implementation would otherwise report "rejected" for every row and look
;; like a self-consistent opinion. See the same note in the PoW driver.
(if (not (string? (digest->hex (shavar-digest/iv (hex->bytevector "616263") 24 sha256-iv 64))))
    (error "shavar-digest/iv did not return a digest"))
(define (num s)
  (let loop ((i 0) (neg #f) (v 0))
    (cond ((= i (string-length s)) (if neg (- v) v))
          ((char=? (string-ref s i) #\-) (loop (+ i 1) #t v))
          (else (loop (+ i 1) neg (+ (* v 10)
                                     (- (char->integer (string-ref s i)) 48)))))))
(define (field line)
  (let loop ((i 0))
    (if (or (= i (string-length line)) (char=? (string-ref line i) #\tab))
        (substring line 0 i)
        (loop (+ i 1)))))
(call-with-input-file (cadr (command-line))
  (lambda (port)
    (let loop ()
      (let ((line (read-line port)))
        (if (eof-object? line)
            #t
            (begin
              (if (and (> (string-length line) 0)
                       (not (char=? (string-ref line 0) #\#)))
                  (let* ((r (num (field line))))
                    (guard (e (#t (display r) (display "\trejected\t-") (newline)))
                      (let ((d (digest->hex
                                (shavar-digest/iv (hex->bytevector "616263") 24
                                                  sha256-iv r))))
                        (display r) (display "\taccepted\t") (display d) (newline)))))
              (loop)))))))
