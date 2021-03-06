;;; Compiles scheme expressions into register machine codes.  Use
;;; lexical addressing to speed up variable lookup and the arithmetic
;;; operations are open-coded.
(load "eceval.scm")

(define (compile* exp target linkage env)
  (cond ((self-evaluating? exp)
         (compile-self-evaluating exp target linkage))
        ((quoted? exp) (compile-quoted exp target linkage))
        ((variable? exp)
         (compile-variable exp target linkage env))
        ((assignment? exp)
         (compile-assignment exp target linkage env))
        ((definition? exp)
         (compile-definition exp target linkage env))
        ((if? exp) (compile-if exp target linkage env))
        ((lambda? exp) (compile-lambda exp target linkage env))
        ((let? exp)
         (compile* (let->combination exp) target linkage env))
        ((begin? exp)
         (compile-sequence (begin-actions exp)
                           target
                           linkage
                           env))
        ((cond? exp) (compile* (cond->if exp) target linkage env))
        ((open-coded-application? exp env)
         (compile-open-coded-primitive exp
                                       target
                                       linkage
                                       env))
        ((application? exp)
         (compile-application exp target linkage env))
        (else
         (error "Unknown expression type -- COMPILE" exp))))

(define (make-instruction-sequence needs modifies statements)
  (list needs modifies statements))

(define (empty-instruction-sequence)
  (make-instruction-sequence '() '() '()))

(define (compile-linkage linkage)
  (cond ((eq? linkage 'return)
         (make-instruction-sequence
          '(continue) '() '((goto (reg continue)))))
        ((eq? linkage 'next)
         (empty-instruction-sequence))
        (else
         (make-instruction-sequence
          '() '() `((goto (label ,linkage)))))))

(define (end-with-linkage linkage instruction-sequence)
  (preserving '(continue)
              instruction-sequence
              (compile-linkage linkage)))

(define (find-variable var env)
  (define (env-loop frame-num env)
    (define (scan disp-num vars)
      (cond ((null? vars)
             (env-loop (+ frame-num 1)
                       (enclosing-environment env)))
            ((eq? var (car vars))
             (make-lex-add frame-num disp-num))
            (else (scan (+ 1 disp-num) (cdr vars)))))
    (if (eq? env the-empty-comp-time-env)
        'not-found
        (scan 0 (first-frame env))))
  (env-loop 0 env))

(define (compile-self-evaluating exp target linkage)
  (end-with-linkage linkage
                    (make-instruction-sequence
                     '()
                     (list target)
                     `((assign ,target (const ,exp))))))
(define (compile-quoted exp target linkage)
  (end-with-linkage linkage
                    (make-instruction-sequence
                     '()
                     (list target)
                     `((assign ,target (const ,(text-of-quotation exp)))))))

(define (compile-variable exp target linkage env)
  (end-with-linkage
   linkage
   (make-instruction-sequence
    '(env)
    (list target)
    (let ((lex-add (find-variable exp env)))
      (if (eq? lex-add 'not-found)
          `((assign ,target
                    (op lookup-in-globenv)
                    (const ,exp)))
          `((assign ,target
                    (op lexical-address-lookup)
                    (const ,lex-add)
                    (reg env))))))))

(define (compile-assignment exp target linkage env)
  (let ((var (assignment-variable exp))
        (get-value-code
         (compile* (assignment-value exp) 'val 'next env)))
    (end-with-linkage
     linkage
     (preserving
      '(env)
      get-value-code
      (make-instruction-sequence
       '(env val)
       (list target)
       (let ((lex-add (find-variable var env)))
         (cond ((eq? lex-add 'not-found)
                (when (open-coded-primitive? var)
                  (drop-open-coded-primitive var))
                `((perform (op set-global-environment!)
                           (const ,var)
                           (reg val))
                  (assign ,target (const ok))))
               (else
                `((perform (op lexical-address-set!)
                           (const ,lex-add)
                           (reg val)
                           (reg env))
                  (assign ,target (const ok)))))))))))

(define (compile-definition exp target linkage env)
  (let ((var (definition-variable exp))
        (get-value-code
         (compile* (definition-value exp) 'val 'next env)))
    (when (and (open-coded-primitive? var)
               (eq? 'not-found
                    (find-variable var env)))
      (drop-open-coded-primitive var))
    (end-with-linkage
     linkage
     (preserving '(env)
                 get-value-code
                 (make-instruction-sequence
                  '(env val)
                  (list target)
                  `((perform (op define-variable!)
                             (const ,var)
                             (reg val)
                             (reg env))
                    (assign ,target (const ok))))))))

(define label-counter 0)

(define (new-label-number)
  (set! label-counter (+ 1 label-counter))
  label-counter)

(define (make-label name)
  (string->symbol
   (string-append (symbol->string name)
                  (number->string (new-label-number)))))

(define (compile-if exp target linkage env)
  (let ((t-branch (make-label 'true-branch))
        (f-branch (make-label 'false-branch))
        (after-if (make-label 'after-if)))
    (let ((consequent-linkage
           (if (eq? linkage 'next) after-if linkage)))
      (let ((p-code (compile* (if-predicate exp) 'val 'next env))
            (c-code
             (compile* (if-consequent exp) target consequent-linkage env))
            (a-code
             (compile* (if-alternative exp) target linkage env)))
        (preserving
         '(env continue)
         p-code
         (append-instruction-sequences
          (make-instruction-sequence
           '(val)
           '()
           `((test (op false?) (reg val))
             (branch (label ,f-branch))))
          (parallel-instruction-sequences
           (append-instruction-sequences t-branch c-code)
           (append-instruction-sequences f-branch a-code))
          after-if))))))

(define (compile-sequence seq target linkage env)
  (if (last-exp? seq)
      (compile* (first-exp seq) target linkage env)
      (preserving '(env continue)
                  (compile* (first-exp seq) target 'next env)
                  (compile-sequence (rest-exps seq) target linkage env))))

(define (compile-lambda exp target linkage env)
  (let ((proc-entry (make-label 'entry))
        (after-lambda (make-label 'after-lambda)))
    (let ((lambda-linkage
           (if (eq? linkage 'next) after-lambda linkage)))
      (append-instruction-sequences
       (tack-on-instruction-sequence
        (end-with-linkage
         lambda-linkage
         (make-instruction-sequence
          '(env)
          (list target)
          `((assign ,target
                    (op make-compiled-procedure)
                    (label ,proc-entry)
                    (reg env)))))
        (compile-lambda-body exp proc-entry env))
       after-lambda))))

(define (scan-out-defines body)
  (define (loop body vars vals new-body)
    (cond ((null? body)
           (let ((vars (reverse vars))
                 (vals (reverse vals))
                 (body (reverse new-body)))
             (if (null? vars)
                 body
                 `((let ,(map (lambda (var)
                                `(,var '*unassigned*))
                              vars)
                     ,@(map (lambda (var val)
                              `(set! ,var ,val))
                            vars
                            vals)
                     ,@body)))))
          ((definition? (car body))
           (loop (cdr body)
                 (cons (definition-variable (car body))
                       vars)
                 (cons (definition-value (car body))
                       vals)
                 new-body))
          (else
           (loop (cdr body)
                 vars
                 vals
                 (cons (car body) new-body)))))
  (loop body '() '() '()))

(define (extend-comp-time-env parms env)
  (cons parms env))
(define the-empty-comp-time-env '())

(define (compile-lambda-body exp proc-entry env)
  (let ((formals (lambda-parameters exp)))
    (append-instruction-sequences
     (make-instruction-sequence
      '(env proc argl)
      '(env)
      `(,proc-entry
        (assign env
                (op compiled-procedure-env)
                (reg proc))
        (assign env
                (op extend-environment)
                (const ,formals)
                (reg argl)
                (reg env))))
     (compile-sequence (scan-out-defines (lambda-body exp))
                       'val
                       'return
                       (extend-comp-time-env formals env)))))

(define (open-coded-application? exp env)
  (and (pair? exp)
       (open-coded-primitive? (operator exp))
       (eq? 'not-found
            (find-variable (operator exp) env))))

(define (spread-arguments operator
                          operand1
                          operand2
                          target
                          linkage
                          env)
  (preserving
   '(continue env)
   (compile* operand1 'arg1 'next env)
   (preserving '(arg1 continue)
               (compile* operand2 'arg2 'next env)
               (end-with-linkage
                linkage
                (make-instruction-sequence
                 '(arg1 arg2)
                 (list target)
                 `((assign ,target
                           (op ,operator)
                           (reg arg1)
                           (reg arg2))))))))

(define (compile-open-coded-primitive exp
                                      target
                                      linkage
                                      env)
  (define (->2args exp)
    (let ((op (operator exp)))
      (let loop ((operand1 (car (operands exp)))
                 (rest-operands (cdr (operands exp))))
        (if (null? rest-operands)
            operand1
            (loop `(,op ,operand1
                        ,(car rest-operands))
                  (cdr rest-operands))))))
  (let ((exp (->2args exp)))
    (spread-arguments (operator exp)
                      (car (operands exp))
                      (cadr (operands exp))
                      target
                      linkage
                      env)))

(define (compile-application exp target linkage env)
  (let ((proc-code (compile* (operator exp) 'proc 'next env))
        (operand-codes
         (map (lambda (operand) (compile* operand 'val 'next env))
              (operands exp))))
    (preserving '(env continue)
                proc-code
                (preserving '(proc continue)
                            (construct-arglist operand-codes)
                            (compile-procedure-call target linkage)))))

(define (construct-arglist operand-codes)
  (let ((operand-codes (reverse operand-codes)))
    (if (null? operand-codes)
        (make-instruction-sequence
         '()
         '(argl)
         '((assign argl (const ()))))
        (let ((code-to-get-last-arg
               (append-instruction-sequences
                (car operand-codes)
                (make-instruction-sequence
                 '(val)
                 '(argl)
                 '((assign argl (op list) (reg val)))))))
          (if (null? (cdr operand-codes))
              code-to-get-last-arg
              (preserving '(env)
                          code-to-get-last-arg
                          (code-to-get-rest-args
                           (cdr operand-codes))))))))
(define (code-to-get-rest-args operand-codes)
  (let ((code-for-next-arg
         (preserving
          '(argl)
          (car operand-codes)
          (make-instruction-sequence
           '(val argl)
           '(argl)
           '((assign argl (op cons) (reg val) (reg argl)))))))
    (if (null? (cdr operand-codes))
        code-for-next-arg
        (preserving '(env)
                    code-for-next-arg
                    (code-to-get-rest-args (cdr operand-codes))))))

(define (compile-procedure-call target linkage)
  (let ((primitive-branch (make-label 'primitive-branch))
        (compiled-branch (make-label 'compiled-branch))
        (interpreted-branch (make-label 'interpreted-branch))
        (after-call (make-label 'after-call)))
    (let ((nonprim-linkage
           (if (eq? linkage 'next) after-call linkage)))
      (append-instruction-sequences
       (make-instruction-sequence
        '(proc)
        '()
        `((test (op primitive-procedure?) (reg proc))
          (branch (label ,primitive-branch))
          (test (op compiled-procedure?) (reg proc))
          (branch (label ,compiled-branch))))
       (parallel-instruction-sequences
        (append-instruction-sequences
         interpreted-branch
         (interpreted-proc-appl target nonprim-linkage))
        (parallel-instruction-sequences
         (append-instruction-sequences
          compiled-branch
          (compile-proc-appl target nonprim-linkage))
         (append-instruction-sequences
          primitive-branch
          (end-with-linkage
           linkage
           (make-instruction-sequence
            '(proc argl)
            (list target)
            `((assign ,target
                      (op apply-primitive-procedure)
                      (reg proc)
                      (reg argl))))))))
       after-call))))

(define all-regs '(env proc val argl continue arg1 arg2))

(define (compile-proc-appl target linkage)
  (cond ((and (eq? target 'val) (not (eq? linkage 'return)))
         (make-instruction-sequence
          '(proc)
          all-regs
          `((assign continue (label ,linkage))
            (assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val))
              (not (eq? linkage 'return)))
         (let ((proc-return (make-label 'proc-return)))
           (make-instruction-sequence
            '(proc)
            all-regs
            `((assign continue (label ,proc-return))
              (assign val (op compiled-procedure-entry) (reg proc))
              (goto (reg val))
              ,proc-return
              (assign ,target (reg val))
              (goto (label ,linkage))))))
        ((and (eq? target 'val) (eq? linkage 'return))
         (make-instruction-sequence
          '(proc continue)
          all-regs
          '((assign val (op compiled-procedure-entry) (reg proc))
            (goto (reg val)))))
        ((and (not (eq? target 'val)) (eq? linkage 'return))
         (error "return linkage, target not val -- COMPILE"
                target))))

(define (interpreted-proc-appl target linkage)
  (cond ((and (eq? target 'val)
              (not (eq? linkage 'return)))
         (make-instruction-sequence
          '(proc)
          all-regs
          `((assign continue (label ,linkage))
            (save continue)
            (goto (reg compapp)))))
        ((and (not (eq? target 'val))
              (not (eq? linkage 'return)))
         (let ((proc-return (make-label 'proc-return)))
           (make-instruction-sequence
            '(proc)
            all-regs
            `((assign continue (label ,proc-return))
              (save continue)
              (goto (reg compapp))
              ,proc-return
              (assign ,target (reg val))
              (goto (label ,linkage))))))
        ((and (eq? target 'val) (eq? linkage 'return))
         (make-instruction-sequence
          '(proc)
          all-regs
          '((save continue)
            (goto (reg compapp)))))
        ((and (not (eq? target 'val))
              (eq? linkage 'return))
         (error
          "return linkage, target not val -- COMPILE"
          target))))

(define (registers-needed s)
  (if (symbol? s) '() (car s)))
(define (registers-modified s)
  (if (symbol? s) '() (cadr s)))
(define (statements s)
  (if (symbol? s) (list s) (caddr s)))

(define (needs-register? seq reg)
  (memq reg (registers-needed seq)))
(define (modifies-register? seq reg)
  (memq reg (registers-modified seq)))

(define (append-instruction-sequences . seqs)
  (define (append-2-sequences seq1 seq2)
    (make-instruction-sequence
     (list-union (registers-needed seq1)
                 (list-difference (registers-needed seq2)
                                  (registers-modified seq1)))
     (list-union (registers-modified seq1)
                 (registers-modified seq2))
     (append (statements seq1) (statements seq2))))
  (define (append-seq-list seqs)
    (if (null? seqs)
        (empty-instruction-sequence)
        (append-2-sequences (car seqs)
                            (append-seq-list (cdr seqs)))))
  (append-seq-list seqs))

(define (list-union s1 s2)
  (cond ((null? s1) s2)
        ((memq (car s1) s2) (list-union (cdr s1) s2))
        (else (cons (car s1) (list-union (cdr s1) s2)))))
(define (list-difference s1 s2)
  (cond ((null? s1) '())
        ((memq (car s1) s2) (list-difference (cdr s1) s2))
        (else (cons (car s1)
                    (list-difference (cdr s1) s2)))))

(define (preserving regs seq1 seq2)
  (if (null? regs)
      (append-instruction-sequences seq1 seq2)
      (let ((first-reg (car regs)))
        (if (and (needs-register? seq2 first-reg)
                 (modifies-register? seq1 first-reg))
            (preserving
             (cdr regs)
             (make-instruction-sequence
              (list-union (list first-reg)
                          (registers-needed seq1))
              (list-difference (registers-modified seq1)
                               (list first-reg))
              (append `((save ,first-reg))
                      (statements seq1)
                      `((restore ,first-reg))))
             seq2)
            (preserving (cdr regs) seq1 seq2)))))

(define (tack-on-instruction-sequence seq body-seq)
  (make-instruction-sequence
   (registers-needed seq)
   (registers-modified seq)
   (append (statements seq) (statements body-seq))))

(define (parallel-instruction-sequences seq1 seq2)
  (make-instruction-sequence
   (list-union (registers-needed seq1)
               (registers-needed seq2))
   (list-union (registers-modified seq1)
               (registers-modified seq2))
   (append (statements seq1) (statements seq2))))

(define library
  '((define (map fn lst)
       (if (null? lst)
           '()
           (cons (fn (car lst))
                 (map fn (cdr lst)))))

     (define (filter pred? lst)
       (cond ((null? lst) '())
             ((pred? (car lst))
              (cons (car lst)
                    (filter pred? (cdr lst))))
             (else
              (filter pred? (cdr lst)))))

     (define (foldl fn init lst)
       (if (null? lst)
           init
           (foldl fn
                  (fn (car lst) init)
                  (cdr lst))))

     (define (for-each fn lst)
      (if (null? lst)
          'done
          (begin
            (fn (car lst))
            (for-each fn (cdr lst)))))))

(define (compile-and-go expression)
  (let ((instructions
         (assemble (statements
                    (compile* `(begin
                                 ,@library
                                 ,expression)
                              'val
                              'return
                              the-empty-comp-time-env))
                   eceval)))
    (set! the-global-environment (setup-environment))
    (set-register-contents! eceval 'val instructions)
    (set-register-contents! eceval 'flag #t)
    (start eceval)))