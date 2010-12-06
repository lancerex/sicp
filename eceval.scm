;;; Explicit-control evaluator
(require r5rs/init)
(load "eval.scm")
(load "regm.scm")

(define (empty-arglist) '())

(define (adjoin-arg arg arglist)
  (append arglist (list arg)))

(define (last-operand? ops)
  (null? (cdr ops)))

(define the-global-environment (setup-environment))
(define (get-global-environment)
  the-global-environment)

(define eceval-operations
  (list (list 'prompt-for-input prompt-for-input)
        (list 'read read)
        (list 'get-global-environment get-global-environment)
        (list 'announce-output announce-output)
        (list 'user-print user-print)
        (list 'self-evaluating? self-evaluating?)
        (list 'variable? variable?)
        (list 'quoted? quoted?)
        (list 'assignment? assignment?)
        (list 'definition? definition?)
        (list 'if? if?)
        (list 'lambda? lambda?)
        (list 'begin? begin?)
        (list 'application? application?)
        (list 'lookup-variable-value lookup-variable-value)
        (list 'text-of-quotation text-of-quotation)
        (list 'lambda-parameters lambda-parameters)
        (list 'lambda-body lambda-body)
        (list 'make-procedure make-procedure)
        (list 'operands operands)
        (list 'operator operator)
        (list 'empty-arglist empty-arglist)
        (list 'no-operands? no-operands?)
        (list 'first-operand first-operand)
        (list 'last-operand? last-operand?)
        (list 'adjoin-arg adjoin-arg)
        (list 'rest-operands rest-operands)
        (list 'adjoin-arg adjoin-arg)
        (list 'primitive-procedure? primitive-procedure?)
        (list 'compound-procedure? compound-procedure?)
        (list 'procedure-parameters procedure-parameters)
        (list 'procedure-environment procedure-environment)
        (list 'extend-environment extend-environment)
        (list 'procedure-body procedure-body)
        (list 'begin-actions begin-actions)
        (list 'first-exp first-exp)
        (list 'last-exp? last-exp?)
        (list 'rest-exps rest-exps)
        (list 'if-predicate if-predicate)
        (list 'true? true?)
        (list 'if-alternative if-alternative)
        (list 'if-consequent if-consequent)
        (list 'assignment-variable assignment-variable)
        (list 'assignment-value assignment-value)
        (list 'set-variable-value! set-variable-value!)
        (list 'definition-variable definition-variable)
        (list 'definition-value definition-value)
        (list 'define-variable! define-variable!)
        (list 'user-print user-print)
        (list 'apply-primitive-procedure apply-primitive-procedure)
        (list 'cond? cond?)
        (list 'cond->if cond->if)
        (list 'let? let?)
        (list 'let->combination let->combination)))

(define eceval
  (make-machine
   eceval-operations
   '(READ-EVAL-PRINT-LOOP
     (perform (op initialize-stack))
     (perform (op prompt-for-input) (const ";;; EC-EVAL input:"))
     (assign exp (op read))
     (assign env (op get-global-environment))
     (assign continue (label PRINT-RESULT))
     (goto (label EVAL-DISPATCH))
     PRINT-RESULT
     (perform (op announce-output) (const ";;; EC-Eval value:"))
     (perform (op user-print) (reg val))
     (goto (label READ-EVAL-PRINT-LOOP))

     EVAL-DISPATCH
     (test (op self-evaluating?) (reg exp))
     (branch (label EV-SELF-EVAL))
     (test (op variable?) (reg exp))
     (branch (label EV-VARIABLE))
     (test (op quoted?) (reg exp))
     (branch (label EV-QUOTED))
     (test (op assignment?) (reg exp))
     (branch (label EV-ASSIGNMENT))
     (test (op definition?) (reg exp))
     (branch (label EV-DEFINITION))
     (test (op if?) (reg exp))
     (branch (label EV-IF))
     (test (op lambda?) (reg exp))
     (branch (label EV-LAMBDA))
     (test (op begin?) (reg exp))
     (branch (label EV-BEGIN))
     (test (op cond?) (reg exp))
     (branch (label EV-COND))
     (test (op let?) (reg exp))
     (branch (label EV-LET))
     (test (op application?) (reg exp))
     (branch (label EV-APPLICATION))
     (goto (label UNKNOWN-EXPRESSION-TYPE))

     EV-SELF-EVAL
     (assign val (reg exp))
     (goto (reg continue))

     EV-VARIABLE
     (assign val (op lookup-variable-value) (reg exp) (reg env))
     (goto (reg continue))

     EV-QUOTED
     (assign val (op text-of-quotation) (reg exp))
     (goto (reg continue))

     EV-LAMBDA
     (assign unev (op lambda-parameters) (reg exp))
     (assign exp (op lambda-body) (reg exp))
     (assign val (op make-procedure) (reg unev) (reg exp) (reg env))
     (goto (reg continue))

     EV-APPLICATION
     (save continue)
     (save env)
     (assign unev (op operands) (reg exp))
     (save unev)
     (assign exp (op operator) (reg exp))
     (assign continue (label EV-APPL-DID-OPERATOR))
     (goto (label EVAL-DISPATCH))
     EV-APPL-DID-OPERATOR
     (restore unev)                     ; the operands
     (restore env)
     (assign argl (op empty-arglist))
     (assign proc (reg val))            ; the operator
     (test (op no-operands?) (reg unev))
     (branch (label APPLY-DISPATCH))
     (save proc)
     EV-APPL-OPERAND-LOOP
     (save argl)
     (assign exp (op first-operand) (reg unev))
     (test (op last-operand?) (reg unev))
     (branch (label EV-APPL-LAST-ARG))
     (save env)
     (save unev)
     (assign continue (label EV-APPL-ACCUMULATE-ARG))
     (goto (label EVAL-DISPATCH))
     EV-APPL-ACCUMULATE-ARG
     (restore unev)
     (restore env)
     (restore argl)
     (assign argl (op adjoin-arg) (reg val) (reg argl))
     (assign unev (op rest-operands) (reg unev))
     (goto (label EV-APPL-OPERAND-LOOP))
     EV-APPL-LAST-ARG
     (assign continue (label EV-APPL-ACCUM-LAST-ARG))
     (goto (label EVAL-DISPATCH))
     EV-APPL-ACCUM-LAST-ARG
     (restore argl)
     (assign argl (op adjoin-arg) (reg val) (reg argl))
     (restore proc)
     (goto (label APPLY-DISPATCH))

     APPLY-DISPATCH
     (test (op primitive-procedure?) (reg proc))
     (branch (label PRIMITIVE-APPLY))
     (test (op compound-procedure?) (reg proc))
     (branch (label COMPOUND-APPLY))
     (goto (label UNKNOWN-PROCEDURE-TYPE))

     PRIMITIVE-APPLY
     (assign val (op apply-primitive-procedure) (reg proc) (reg argl))
     (restore continue)
     (goto (reg continue))

     COMPOUND-APPLY
     (assign unev (op procedure-parameters) (reg proc))
     (assign env (op procedure-environment) (reg proc))
     (assign env (op extend-environment) (reg unev) (reg argl) (reg env))
     (assign unev (op procedure-body) (reg proc))
     (goto (label EV-SEQUENCE))

     EV-BEGIN
     (assign unev (op begin-actions) (reg exp))
     (save continue)
     (goto (label EV-SEQUENCE))

     EV-SEQUENCE
     (assign exp (op first-exp) (reg unev))
     (test (op last-exp?) (reg unev))
     (branch (label EV-SEQUENCE-LAST-EXP))
     (save unev)
     (save env)
     (assign continue (label EV-SEQUENCE-CONTINUE))
     (goto (label EVAL-DISPATCH))
     EV-SEQUENCE-CONTINUE
     (restore env)
     (restore unev)
     (assign unev (op rest-exps) (reg unev))
     (goto (label EV-SEQUENCE))
     EV-SEQUENCE-LAST-EXP
     (restore continue)
     (goto (label EVAL-DISPATCH))

     EV-IF
     (save exp)                         ; save expression for later
     (save env)
     (save continue)
     (assign continue (label EV-IF-DECIDE))
     (assign exp (op if-predicate) (reg exp))
     (goto (label EVAL-DISPATCH))       ; evaluate the predicate
     EV-IF-DECIDE
     (restore continue)
     (restore env)
     (restore exp)
     (test (op true?) (reg val))
     (branch (label EV-IF-CONSEQUENT))
     EV-IF-ALTERNATIVE
     (assign exp (op if-alternative) (reg exp))
     (goto (label EVAL-DISPATCH))
     EV-IF-CONSEQUENT
     (assign exp (op if-consequent) (reg exp))
     (goto (label EVAL-DISPATCH))

     EV-ASSIGNMENT
     (assign unev (op assignment-variable) (reg exp))
     (save unev)                        ; save variable for later
     (assign exp (op assignment-value) (reg exp))
     (save env)
     (save continue)
     (assign continue (label EV-ASSIGNMENT-1))
     (goto (label EVAL-DISPATCH))       ; evaluate he assignment value
     EV-ASSIGNMENT-1
     (restore continue)
     (restore env)
     (restore unev)
     (perform
      (op set-variable-value!) (reg unev) (reg val) (reg env))
     (assign val (const ok))
     (goto (reg continue))

     EV-DEFINITION
     (assign unev (op definition-variable) (reg exp))
     (save unev)                        ; save variable for later
     (assign exp (op definition-value) (reg exp))
     (save env)
     (save continue)
     (assign continue (label EV-DEFINITION-1))
     (goto (label EVAL-DISPATCH))      ; evaluate the definition value
     EV-DEFINITION-1
     (restore continue)
     (restore env)
     (restore unev)
     (perform
      (op define-variable!) (reg unev) (reg val) (reg env))
     (assign val (const ok))
     (goto (reg continue))

     EV-COND
     (assign exp (op cond->if) (reg exp))
     (goto (label EVAL-DISPATCH))

     EV-LET
     (assign exp (op let->combination) (reg exp))
     (goto (label EVAL-DISPATCH))

     UNKNOWN-EXPRESSION-TYPE
     (assign val (const unknown-expression-type-error))
     (goto (label signal-error))
     UNKNOWN-PROCEDURE-TYPE
     (restore continue)         ; clean up stack (from apply-dispatch)
     (assign val (const unknown-procedure-type-error))
     (goto (label SIGNAL-ERROR))
     SIGNAL-ERROR
     (perform (op user-print) (reg val))
     (goto (label READ-EVAL-PRINT-LOOP)))))