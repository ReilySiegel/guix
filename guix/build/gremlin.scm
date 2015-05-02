;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix build gremlin)
  #:use-module (guix elf)
  #:use-module ((guix build utils) #:select (store-file-name?))
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-35)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (rnrs io ports)
  #:export (elf-error?
            elf-error-elf
            invalid-segment-size?
            invalid-segment-size-segment

            elf-dynamic-info
            elf-dynamic-info?
            elf-dynamic-info-sopath
            elf-dynamic-info-needed
            elf-dynamic-info-rpath
            elf-dynamic-info-runpath
            expand-origin

            validate-needed-in-runpath))

;;; Commentary:
;;;
;;; A gremlin is sort-of like an elf, you know, and this module provides tools
;;; to deal with dynamic-link information from ELF files.
;;;
;;; Code:

(define-condition-type &elf-error &error
  elf-error?
  (elf elf-error-elf))

(define-condition-type &invalid-segment-size &elf-error
  invalid-segment-size?
  (segment invalid-segment-size-segment))


(define (dynamic-link-segment elf)
  "Return the 'PT_DYNAMIC' segment of ELF--i.e., the segment that contains
dynamic linking information."
  (let ((size (bytevector-length (elf-bytes elf))))
    (find (lambda (segment)
            (unless (<= (+ (elf-segment-offset segment)
                           (elf-segment-filesz segment))
                        size)
              ;; This happens on separate debug output files created by
              ;; 'strip --only-keep-debug' (Binutils 2.25.)
              (raise (condition (&invalid-segment-size
                                 (elf elf)
                                 (segment segment)))))

            (= (elf-segment-type segment) PT_DYNAMIC))
          (elf-segments elf))))

(define (word-reader size byte-order)
  "Return a procedure to read a word of SIZE bytes according to BYTE-ORDER."
  (case size
    ((8)
     (lambda (bv index)
       (bytevector-u64-ref bv index byte-order)))
    ((4)
     (lambda (bv index)
       (bytevector-u32-ref bv index byte-order)))))


;; Dynamic entry:
;;
;; typedef struct
;; {
;;   Elf64_Sxword       d_tag;   /* Dynamic entry type */
;;   union
;;     {
;;       Elf64_Xword d_val;      /* Integer value */
;;       Elf64_Addr d_ptr;       /* Address value */
;;     } d_un;
;; } Elf64_Dyn;

(define (raw-dynamic-entries elf segment)
  "Return as a list of type/value pairs all the dynamic entries found in
SEGMENT, the 'PT_DYNAMIC' segment of ELF.  In the result, each car is a DT_
value, and the interpretation of the cdr depends on the type."
  (define start
    (elf-segment-offset segment))
  (define bytes
    (elf-bytes elf))
  (define word-size
    (elf-word-size elf))
  (define byte-order
    (elf-byte-order elf))
  (define read-word
    (word-reader word-size byte-order))

  (let loop ((offset 0)
             (result '()))
    (if (>= offset (elf-segment-memsz segment))
        (reverse result)
        (let ((type  (read-word bytes (+ start offset)))
              (value (read-word bytes (+ start offset word-size))))
          (if (= type DT_NULL)                    ;finished?
              (reverse result)
              (loop (+ offset (* 2 word-size))
                    (alist-cons type value result)))))))

(define (vma->offset elf vma)
  "Convert VMA, a virtual memory address, to an offset within ELF.

Do that by looking at the loadable program segment (PT_LOAD) of ELF that
contains VMA and by taking into account that segment's virtual address and
offset."
  ;; See 'offset_from_vma' in Binutils.
  (define loads
    (filter (lambda (segment)
              (= (elf-segment-type segment) PT_LOAD))
            (elf-segments elf)))

  (let ((load (find (lambda (segment)
                      (let ((vaddr (elf-segment-vaddr segment)))
                        (and (>= vma vaddr)
                             (< vma (+ (elf-segment-memsz segment)
                                       vaddr)))))
                    loads)))
    (+ (- vma (elf-segment-vaddr load))
       (elf-segment-offset load))))

(define (dynamic-entries elf segment)
  "Return all the dynamic entries found in SEGMENT, the 'PT_DYNAMIC' segment
of ELF, as a list of type/value pairs.  The type is a DT_ value, and the value
may be a string or an integer depending on the entry type (for instance, the
value of DT_NEEDED entries is a string.)"
  (define entries
    (raw-dynamic-entries elf segment))

  (define string-table-offset
    (any (match-lambda
            ((type . value)
             (and (= type DT_STRTAB) value))
            (_ #f))
         entries))

  (define (interpret-dynamic-entry type value)
    (cond ((memv type (list DT_NEEDED DT_SONAME DT_RPATH DT_RUNPATH))
           (if string-table-offset
               (pointer->string
                (bytevector->pointer (elf-bytes elf)
                                     (vma->offset
                                      elf
                                      (+ string-table-offset value))))
               value))
          (else
           value)))

  (map (match-lambda
         ((type . value)
          (cons type (interpret-dynamic-entry type value))))
       entries))


;;;
;;; High-level interface.
;;;

(define-record-type <elf-dynamic-info>
  (%elf-dynamic-info soname needed rpath runpath)
  elf-dynamic-info?
  (soname    elf-dynamic-info-soname)
  (needed    elf-dynamic-info-needed)
  (rpath     elf-dynamic-info-rpath)
  (runpath   elf-dynamic-info-runpath))

(define search-path->list
  (let ((not-colon (char-set-complement (char-set #\:))))
    (lambda (str)
      "Split STR on ':' characters."
      (string-tokenize str not-colon))))

(define (elf-dynamic-info elf)
  "Return dynamic-link information for ELF as an <elf-dynamic-info> object, or
#f if ELF lacks dynamic-link information."
  (match (dynamic-link-segment elf)
    (#f #f)
    ((? elf-segment? dynamic)
     (let ((entries (dynamic-entries elf dynamic)))
       (%elf-dynamic-info (assv-ref entries DT_SONAME)
                          (filter-map (match-lambda
                                        ((type . value)
                                         (and (= type DT_NEEDED) value))
                                        (_ #f))
                                      entries)
                          (or (and=> (assv-ref entries DT_RPATH)
                                     search-path->list)
                              '())
                          (or (and=> (assv-ref entries DT_RUNPATH)
                                     search-path->list)
                              '()))))))

(define %libc-libraries
  ;; List of libraries as of glibc 2.21 (there are more but those are
  ;; typically mean to be LD_PRELOADed and thus do not appear as NEEDED.)
  '("libanl.so"
    "libcrypt.so"
    "libc.so"
    "libdl.so"
    "libm.so"
    "libnsl.so"                                   ;NEEDED by nscd
    "libpthread.so"
    "libresolv.so"
    "librt.so"
    "libutil.so"))

(define (libc-library? lib)
  "Return #t if LIB is one of the libraries shipped with the GNU C Library."
  (find (lambda (libc-lib)
          (string-prefix? libc-lib lib))
        %libc-libraries))

(define (expand-variable str variable value)
  "Replace occurrences of '$VARIABLE' or '${VARIABLE}' in STR with VALUE."
  (define variables
    (list (string-append "$" variable)
          (string-append "${" variable "}")))

  (let loop ((thing variables)
             (str   str))
    (match thing
      (()
       str)
      ((head tail ...)
       (let ((index (string-contains str head))
             (len   (string-length head)))
         (loop (if index variables tail)
               (if index
                   (string-replace str value
                                   index (+ index len))
                   str)))))))

(define (expand-origin str directory)
  "Replace occurrences of '$ORIGIN' in STR with DIRECTORY."
  (expand-variable str "ORIGIN" directory))

(define* (validate-needed-in-runpath file
                                     #:key (always-found? libc-library?))
  "Return #t if all the libraries listed as FILE's 'DT_NEEDED' entries are
present in its RUNPATH, or if FILE lacks dynamic-link information.  Return #f
otherwise.  Libraries whose name matches ALWAYS-FOUND? are considered to be
always available."
  (guard (c ((invalid-segment-size? c)
             (let ((segment (invalid-segment-size-segment c)))
               (format (current-error-port)
                       "~a: error: offset + size of segment ~a (type ~a) \
exceeds total size~%"
                       file
                       (elf-segment-index segment)
                       (elf-segment-type segment))
               #f)))

    (let* ((elf     (call-with-input-file file
                      (compose parse-elf get-bytevector-all)))
           (expand  (cute expand-origin <> (dirname file)))
           (dyninfo (elf-dynamic-info elf)))
      (when dyninfo
        ;; XXX: In theory we should also expand $PLATFORM and $LIB, but these
        ;; appear to be really unused.
        (let* ((expanded  (map expand (elf-dynamic-info-runpath dyninfo)))
               (runpath   (filter store-file-name? expanded))
               (bogus     (remove store-file-name? expanded))
               (needed    (remove always-found?
                                  (elf-dynamic-info-needed dyninfo)))
               (not-found (remove (cut search-path runpath <>)
                                  needed)))
          (unless (null? bogus)
            (format (current-error-port)
                    "~a: warning: RUNPATH contains bogus entries: ~s~%"
                    file bogus))

          (for-each (lambda (lib)
                      (format (current-error-port)
                              "~a: error: depends on '~a', which cannot \
be found in RUNPATH ~s~%"
                              file lib runpath))
                    not-found)
          ;; (when (null? not-found)
          ;;   (format (current-error-port) "~a is OK~%" file))
          (null? not-found))))))

;;; gremlin.scm ends here
