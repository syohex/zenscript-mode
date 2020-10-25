;;; zenscript-language.el --- Tools for understanding ZenScript code. -*- lexical-binding: t -*-

;; Copyright (c) 2020 Eutro

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; ZenScript language module, for parsing and understanding ZenScript.

;;; Code:

(require 'zenscript-common)

(defun zenscript--java-type-to-ztype (symbol)
  "Convert a Java type to a ZenType.

SYMBOL should be a java class name to be looked up in dumpzs."
  (car
   (seq-find (lambda (entry)
	       (equal (cadr entry) symbol))
	     (cdr (assoc "Types" (cdr (zenscript-get-dumpzs)))))))

(defun zenscript--symbol-to-type (symbol)
  "Get the ZenType from a stringified binding object SYMBOL.

If SYMBOL is the string:

 \"SymbolJavaStaticField: public static zenscript.Type ZenScriptGlobals.global\"

Then its ZenType will be resolved by looking up the zsPath of \"zenscript.Type\"."
  (when (string-match "SymbolJavaStatic\\(?:Field\\|\\(Method: JavaMethod\\)\\): public static \\(.+\\) .+$" symbol)
    (concat (if (match-string 1) "=>" "") (zenscript--java-type-to-ztype (match-string 2 symbol)))))

(defun zenscript--buffer-vals ()
  "Get a list of resolvable values in a buffer.

Returns a list of values of the form:

 (name type)

name:

  The name of the value by which it can be referenced.

type:

  The ZenType of the value, its `zsPath` from dumpzs, or nil if unknown."
  (mapcar (lambda (el)
	    (list (car el)
		  (zenscript--symbol-to-type (cadr el))))
	  (cdr (assoc "Globals" (cdr (zenscript-get-dumpzs))))))

(defun zenscript--get-importables-1 (nodes)
  "Get a list of types or static members below NODES in the tree."
  (apply 'append
	 (mapcar (lambda (node)
		   (if (stringp node)
		       (list node)
		     (let ((name (car node)))
		       ;; This operates on the assumption that type names start
		       ;; with capital letters.
		       (if (string= "Lu" (get-char-code-property (string-to-char name)
								 'general-category))
			   (cons name
				 (mapcar (lambda (member)           ; "[STATIC] "
					   (concat name "." (substring member 9)))
					 (seq-filter (lambda (member)
						       (string-match-p "\\[STATIC\\] .+" member))
						     (mapcar (lambda (node)
							       (if (stringp node)
								   node
								 (car node)))
							     (cdr node)))))
			 (mapcar (lambda (importable)
				   (concat name "." importable))
				 (zenscript--get-importables-1 (cdr node)))))))
		 nodes)))

(defun zenscript--get-members (&optional types)
  "Get the known members of the ZenTypes TYPES, or just all known members.

Returns a list of members of the following format:

 (name . extra-info)

name:

  The name of the member.

extra-info:

  A list (possibly nil) of extra information relating to the member."
  (if types
      ()
    (apply 'append
	   (mapcar (lambda (type)
		     (cdr (assoc 'members type)))
		   (cdr (assoc 'zenTypeDumps (car (zenscript-get-dumpzs))))))))

(defun zenscript--get-importables ()
  "Get a list of all things that can be imported: static members and types.

Returns a list of type names that can be imported."
  (zenscript--get-importables-1 (cdr (assoc "Root (Symbol Package)" (cdr (zenscript-get-dumpzs))))))

;;; Parsing:

;; I have written these too many times, so I'm keeping them around.

(defun zenscript--skip-ws-and-comments ()
  "Skip across any whitespace characters or comments."
  (skip-syntax-forward " >")
  (when (>= (point-max) (+ (point) 2))
    (let ((ppss (save-excursion
		  (parse-partial-sexp (point)
				      (+ (point) 2)
				      () () () t))))
      (when (nth 4 ppss)
	(parse-partial-sexp (point)
			    (point-max)
			    () () ppss 'syntax-table)
	(zenscript--skip-ws-and-comments)))))

(defun zenscript--looking-at-backwards-p (regex)
  "Return non-nil if searching REGEX backwards ends at point."
  (= (point)
     (save-excursion
       (or (and (re-search-backward regex (point-min) t)
		(match-end 0))
	   0))))

(defun zenscript--tokenize-buffer (&optional from to no-error)
  "Read the buffer into a list of tokens.

FROM is the start position, and defaults to `point-min`.

TO is the end position, and defaults to `point-max`.

If a token is unrecognised, and NO-ERROR is nil,
`zenscript-unrecognised-token` is thrown.
If NO-ERROR is non-nil, then parsing stops instead, returning the partially
accumulated list of tokens, and leaving point where it is.

If parsing concludes, then point is left at TO.

Note: this uses the syntax table to handle comments."
  (goto-char (or from (point-min)))
  (let ((to (or to (point-max)))
	(continue t)
	tokens)
    (zenscript--skip-ws-and-comments)
    (while (and continue (char-after))
      (let ((start (point))
	    (next-token (zenscript--next-token)))
	(when (or (>= (point) to)
		  (not next-token))
	  (setq continue ()))
	(if next-token
	    (if (> (point) to)
		(goto-char start)
	      (setq tokens (cons next-token tokens))
	      (when (< (point) to)
		(zenscript--skip-ws-and-comments)))
	  (unless no-error
	    (throw 'zenscript-unrecognised-token "Unrecognised token")))))
    (reverse tokens)))

(defconst zenscript--keyword-map
  (let ((table (make-hash-table :size 34
				:test 'equal)))
    (puthash "frigginConstructor" 'T_ZEN_CONSTRUCTOR table)
    (puthash "zenConstructor" 'T_ZEN_CONSTRUCTOR table)
    (puthash "frigginClass" 'T_ZEN_CLASS table)
    (puthash "zenClass" 'T_ZEN_CLASS table)
    (puthash "instanceof" 'T_INSTANCEOF table)
    (puthash "static" 'T_STATIC table)
    (puthash "global" 'T_GLOBAL table)
    (puthash "import" 'T_IMPORT table)
    (puthash "false" 'T_FALSE table)
    (puthash "true" 'T_TRUE table)
    (puthash "null" 'T_NULL table)
    (puthash "break" 'T_BREAK table)
    (puthash "while" 'T_WHILE table)
    (puthash "val" 'T_VAL table)
    (puthash "var" 'T_VAR table)
    (puthash "return" 'T_RETURN table)
    (puthash "for" 'T_FOR table)
    (puthash "else" 'T_ELSE table)
    (puthash "if" 'T_IF table)
    (puthash "version" 'T_VERSION table)
    (puthash "as" 'T_AS table)
    (puthash "void" 'T_VOID table)
    (puthash "has" 'T_IN table)
    (puthash "in" 'T_IN table)
    (puthash "function" 'T_FUNCTION table)
    (puthash "string" 'T_STRING table)
    (puthash "double" 'T_DOUBLE table)
    (puthash "float" 'T_FLOAT table)
    (puthash "long" 'T_LONG table)
    (puthash "int" 'T_INT table)
    (puthash "short" 'T_SHORT table)
    (puthash "byte" 'T_BYTE table)
    (puthash "bool" 'T_BOOL table)
    (puthash "any" 'T_ANY table)
    table)
  "A hash-table of keywords to tokens.")

(defun zenscript--next-token (&optional skip-whitespace)
  "Parse the next ZenScript token after point.

If SKIP-WHITESPACE is non-nil, whitespace and comments
are skipped according to `syntax-table`.

Return a pair of the form

 (type val pos)

or nil if no token was recognised.

type:

  The type of the token, as seen here
  https://docs.blamejared.com/1.12/en/Dev_Area/ZenTokens/

val:

  The string value of the token.

pos:

  The position at which the token occured.

file:

  The file name of the buffer from which the token was read.

point is put after token, if one was found."
  (let ((begin (point)))
    (when skip-whitespace (zenscript--skip-ws-and-comments))
    (if-let ((type (cond ((looking-at "[a-zA-Z_][a-zA-Z_0-9]*")
			  (or (gethash (buffer-substring-no-properties (match-beginning 0)
								       (match-end 0))
				       zenscript--keyword-map)
			      'T_ID))
			 ((looking-at (regexp-quote "{")) 'T_AOPEN)
			 ((looking-at (regexp-quote "}")) 'T_ACLOSE)
			 ((looking-at (regexp-quote "[")) 'T_SQBROPEN)
			 ((looking-at (regexp-quote "]")) 'T_SQBRCLOSE)
			 ((looking-at (regexp-quote "..")) 'T_DOT2)
			 ((looking-at (regexp-quote ".")) 'T_DOT)
			 ((looking-at (regexp-quote ",")) 'T_COMMA)
			 ((looking-at (regexp-quote "+=")) 'T_PLUSASSIGN)
			 ((looking-at (regexp-quote "+")) 'T_PLUS)
			 ((looking-at (regexp-quote "-=")) 'T_MINUSASSIGN)
			 ((looking-at (regexp-quote "-")) 'T_MINUS)
			 ((looking-at (regexp-quote "*=")) 'T_MULASSIGN)
			 ((looking-at (regexp-quote "*")) 'T_MUL)
			 ((looking-at (regexp-quote "/=")) 'T_DIVASSIGN)
			 ((looking-at (regexp-quote "/")) 'T_DIV)
			 ((looking-at (regexp-quote "%=")) 'T_MODASSIGN)
			 ((looking-at (regexp-quote "%")) 'T_MOD)
			 ((looking-at (regexp-quote "|=")) 'T_ORASSIGN)
			 ((looking-at (regexp-quote "||")) 'T_OR2)
			 ((looking-at (regexp-quote "|")) 'T_OR)
			 ((looking-at (regexp-quote "&=")) 'T_ANDASSIGN)
			 ((looking-at (regexp-quote "&&")) 'T_AND2)
			 ((looking-at (regexp-quote "&")) 'T_AND)
			 ((looking-at (regexp-quote "^=")) 'T_XORASSIGN)
			 ((looking-at (regexp-quote "^")) 'T_XOR)
			 ((looking-at (regexp-quote "?")) 'T_QUEST)
			 ((looking-at (regexp-quote ":")) 'T_COLON)
			 ((looking-at (regexp-quote "(")) 'T_BROPEN)
			 ((looking-at (regexp-quote ")")) 'T_BRCLOSE)
			 ((looking-at (regexp-quote "~=")) 'T_TILDEASSIGN)
			 ((looking-at (regexp-quote "~")) 'T_TILDE)
			 ((looking-at (regexp-quote ";")) 'T_SEMICOLON)
			 ((looking-at (regexp-quote "<=")) 'T_LTEQ)
			 ((looking-at (regexp-quote "<")) 'T_LT)
			 ((looking-at (regexp-quote ">=")) 'T_GTEQ)
			 ((looking-at (regexp-quote ">")) 'T_GT)
			 ((looking-at (regexp-quote "==")) 'T_EQ)
			 ((looking-at (regexp-quote "=")) 'T_ASSIGN)
			 ((looking-at (regexp-quote "!=")) 'T_NOTEQ)
			 ((looking-at (regexp-quote "!")) 'T_NOT)
			 ((looking-at (regexp-quote "$")) 'T_DOLLAR)
			 ((looking-at "-?\\(0\\|[1-9][0-9]*\\)\\.[0-9]+\\([eE][+-]?[0-9]+\\)?[fFdD]?")
			  'T_FLOATVALUE)
			 ((or (looking-at "-?\\(0\\|[1-9][0-9]*\\)")
			      (looking-at "0x[a-fA-F0-9]*"))
			  'T_INTVALUE)
			 ((or (looking-at "'\\([^'\\\\]\\|\\\\\\(['\"\\\\/bfnrt]\\|u[0-9a-fA-F]\\{4\\}\\)\\)*?'")
			      (looking-at "\"\\([^\"\\\\]\\|\\\\\\(['\"\\\\/bfnrt]\\|u[0-9a-fA-F]\\{4\\}\\)\\)*\""))
			  'T_STRINGVALUE))))
	(progn (goto-char (match-end 0))
	       (list type
		     (buffer-substring-no-properties (match-beginning 0)
						     (match-end 0))
		     (match-beginning 0)))
      (goto-char begin)
      ())))

(defmacro cdr! (list)
  "Set LIST to the cdr of LIST."
  `(setq ,list (cdr ,list)))

(defmacro cons! (car list)
  "Set LIST to (cons CAR LIST)."
  `(setq ,list (cons ,car ,list)))

(defun zenscript--make-tokenstream (token-list)
  "Make a tokenstream from a list of tokens, TOKEN-LIST."
  (lambda (op &rest args)
    (pcase op
      ('PEEK (car token-list))
      ('NEXT (prog1 (car token-list)
	       (cdr! token-list)))
      ('OPTIONAL (when (eq (car args) (caar token-list))
		   (prog1 (car token-list)
		     (cdr! token-list))))
      ('REQUIRE (if (eq (car args) (caar token-list))
		    (prog1 (car token-list)
		      (cdr! token-list))
		  (throw 'zenscript-parse-error
			 (cadr args)))))))

(defun zenscript--require-token (type tokens message)
  "Require that the next token in TOKENS is of type TYPE.

Return the first token if it is of type TYPE, otherwise
throw 'zenscript-parse-error with MESSAGE.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'REQUIRE type message))

(defun zenscript--peek-token (tokens)
  "Look at the next token in the stream TOKENS, without consuming it.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'PEEK))

(defun zenscript--get-token (tokens)
  "Get the next token in the stream TOKENS, consuming it.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'NEXT))

(defun zenscript--optional-token (type tokens)
  "Get the next token in the stream TOKENS if it is of the type TYPE, or nil.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (funcall tokens 'OPTIONAL type))

(defun zenscript--has-next-token (tokens)
  "Return t if TOKENS has any more tokens remaining.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (when (zenscript--peek-token tokens) t))

(defun zenscript--parse-tokens (tokenlist)
  "Parse a list of ZenScript tokens.

TOKENLIST is a list of tokens of the form

 (type val pos)

As returned by `zenscript--next-token`.

Returns a list of the form

 (imports functions zenclasses statements)

Which are lists of elements of the formats:

imports:

  (fqname pos rename)

  fqname:

    A list of strings representing the fully qualified name.

  pos:

    The position at which the import appears.

  rename:

    The name by which fqname should be referenced, or nil
    if the last name in fqname should be used."
  (let ((tokens (zenscript--make-tokenstream tokenlist))
	imports functions zenclasses statements)
    (while (and (zenscript--has-next-token tokens)
		(eq (car (zenscript--peek-token tokens))
		    'T_IMPORT))
      (let (fqname
	    (pos (caddr (zenscript--get-token tokens)))
	    rename)

	(cons! (cadr (zenscript--require-token 'T_ID tokens
					       "identifier expected"))
	       fqname)
	(while (zenscript--optional-token 'T_DOT tokens)
	  (cons! (cadr (zenscript--require-token 'T_ID tokens
						 "identifier expected"))
		 fqname))

	(when (zenscript--optional-token 'T_AS tokens)
	  (setq rename (cadr (zenscript--require-token 'T_ID tokens
						       "identifier expected"))))

	(zenscript--require-token 'T_SEMICOLON tokens
				  "; expected")

	(cons! (list (reverse fqname)
		     pos
		     rename)
	       imports)))
    (while (zenscript--has-next-token tokens)
      (pcase (car (zenscript--peek-token tokens))
	((or 'T_GLOBAL 'T_STATIC)
	 (cons! (zenscript--parse-global tokens)
		statements))
	('T_FUNCTION
	 (cons! (zenscript--parse-function tokens)
		functions))
	('T_ZEN_CLASS
	 (cons! (zenscript--parse-zenclass tokens)
		zenclasses))
	(_ (cons! (zenscript--parse-statement tokens)
		  statements))))
    (list (reverse imports)
	  (reverse functions)
	  (reverse zenclasses)
	  (reverse statements))))

(defun zenscript--parse-function (tokens)
  "Parse the next static function definition from TOKENS.

Return a list of the form:

 (name arguments type statements)

name:

  The token that is the name of the function.

arguments:

  A list of arguments as returned by `zenscript--parse-function-arguments`.

type:

  The ZenType that the function returns.

statements:

  A list of statements, which are as returned by `zenscript--parse-statement`.

function (argname [as type], argname [as type], ...) [as type] {
...contents... }"
  (zenscript--require-token 'T_FUNCTION tokens
			    "function expected")
  (let ((name (zenscript--require-token 'T_ID tokens
					"identifier expected"))
	(arguments (zenscript--parse-function-arguments tokens))
	(type (if (zenscript--optional-token 'T_AS tokens)
		  (zenscript--parse-zentype tokens)
	      '(C_RAW "any")))
	statements)
    (zenscript--require-token 'T_AOPEN tokens
			      "{ expected")
    (while (not (zenscript--optional-token 'T_ACLOSE tokens))
      (cons! (zenscript--parse-statement tokens) statements))
    (list name
	  arguments
	  type
	  (reverse statements))))

(defun zenscript--parse-function-arguments (tokens)
  "Parse a list of function arguments from TOKENS.

A list of arguments of the form:

 (name type)

name:

  The token that is the identifier of this binding.

type:

  The ZenType of this binding."
  (let (arguments)
    (zenscript--require-token 'T_BROPEN tokens
			      "( expected")
    (unless (zenscript--optional-token 'T_BRCLOSE tokens)
      (let (break)
	(while (not break)
	  (cons! (list (zenscript--require-token 'T_ID tokens
						 "identifier expected")
		       (if (zenscript--optional-token 'T_AS tokens)
			   (zenscript--parse-zentype tokens)
			 '(C_RAW "any")))
		 arguments)
	  (unless (zenscript--optional-token 'T_COMMA tokens)
	    (zenscript--require-token 'T_BRCLOSE tokens
				      ") or , expected")
	    (setq break t)))))
    (reverse arguments)))

(defun zenscript--parse-zenclass (tokens)
  "Parse the next class definition from TOKENS.

A list of the form:

 (name fields constructors methods)

name:

  The token that is the name of this class.

fields:

  A list of fields, which are as returned by
  `zenscript--parse-zenclass-field`.

constructors:

  A list of constructors, which are as returned by
  `zenscript--parse-zenclass-constructor`.

methods:

  A list of methods, which are as returned by
  `zenscript--parse-zenclass-method`."
  (zenscript--require-token 'T_ZEN_CLASS tokens
			    "zenClass expected")
  (let ((id (zenscript--require-token 'T_ID tokens
				      "identifier expected"))
	keyword
	fields constructors methods)
    (zenscript--require-token 'T_AOPEN tokens
			      "{ expected")
    (while (setq keyword
		 (or (zenscript--optional-token 'T_VAL tokens)
		     (zenscript--optional-token 'T_VAR tokens)
		     (zenscript--optional-token 'T_STATIC tokens)
		     (zenscript--optional-token 'T_ZEN_CONSTRUCTOR tokens)
		     (zenscript--optional-token 'T_FUNCTION tokens)))
      (pcase (car keyword)
	((or 'T_VAL 'T_VAR
	     'T_STATIC)
	 (cons! (zenscript--parse-zenclass-field tokens (eq (car keyword)
							    'T_STATIC))
		fields))
	('T_ZEN_CONSTRUCTOR
	 (cons! (zenscript--parse-zenclass-constructor tokens)
		constructors))
	('T_FUNCTION
	 (cons! (zenscript--parse-zenclass-method tokens)
		methods))))
    (zenscript--require-token 'T_ACLOSE tokens
			      "} expected")
    (list id
	  (reverse fields)
	  (reverse constructors)
	  (reverse methods)
	  (caddr id))))

(defun zenscript--parse-zenclass-field (tokens static)
  "Parse a field definition of a ZenClass from TOKENS.

A list of the form:

 (name type init static)

name:

  The token that is the name of this field.

type:

  The ZenType of the field.

init:

  The expression by which this field is initialized.

static:

  t if the field is static, nil otherwise.

STATIC should be true if the class field is static."
  (let ((id (zenscript--require-token 'T_ID tokens
				      "identifier expected"))
	(type (if (zenscript--optional-token 'T_AS tokens)
		  (zenscript--parse-zentype tokens)
		'(C_RAW "any")))
	(init (when (zenscript--optional-token 'T_ASSIGN tokens)
		(zenscript--parse-expression tokens))))
    (zenscript--require-token 'T_SEMICOLON tokens
			      "; expected")
    (list id type init static)))

(defun zenscript--parse-zenclass-constructor (tokens)
  "Parse a constructor definition of a ZenClass from TOKENS.

A list of the form:

 (arguments statements)

arguments:

  The list of arguments, as returned by `zenscript--parse-function-arguments`.

statements:

  A list of statements, which are as returned by `zenscript--parse-statement`."
  (let ((arguments (zenscript--parse-function-arguments tokens))
	statements)
    (zenscript--require-token 'T_AOPEN tokens
			      "{ expected")
    (while (not (zenscript--optional-token 'T_ACLOSE tokens))
      (cons! (zenscript--parse-statement tokens) statements))
    (list arguments (reverse statements))))

(defun zenscript--parse-zenclass-method (tokens)
  "Parse a method definition of a ZenClass from TOKENS.

A list of the form:

 (name arguments type statements)

name:

  The token that is the name of this method.

arguments:

  The list of arguments, as returned by `zenscript--parse-function-arguments`.

type:

  The ZenType that the method returns.

statements:

  A list of statements, which are as returned by `zenscript--parse-statement`."
  (let ((id (zenscript--require-token 'T_ID tokens
				      "identifier expected"))
	(arguments (zenscript--parse-function-arguments tokens))
	(type (if (zenscript--optional-token 'T_AS tokens)
		  (zenscript--parse-zentype tokens)
		'(C_RAW "any")))
	statements)
    (zenscript--require-token 'T_AOPEN tokens
			      "{ expected")
    (while (not (zenscript--optional-token 'T_ACLOSE tokens))
      (cons! (zenscript--parse-statement tokens) statements))
    (list id arguments type (reverse statements))))

(defun zenscript--parse-statement (tokens)
  "Parse the next statement from TOKENS.

A list of the form:

 (type . value)

type:

  The type of the statement, see below for possible values.

value:

  The value of the statement, which varies by type.  See below.

The following types are possible:

  S_BLOCK:

    value: (statements)

    statements:

      A list of statements, which are as returned by
      `zenscript--parse-statement`.

  S_RETURN:

    value: (expression)

    expression:

      An expression that is the value of this return
      statement.  See `zenscript--parse-expression`.

  S_VAR:

    value: (name type initializer final)

    name:

      The token that is the name of this variable.

    type:

      The explicit ZenType of this variable.

    initializer:

      The expression that initializes this variable.

    final:

      t if this variable is final, nil otherwise.

  S_IF:

    value: (predicate then else)

    predicate:

      The expression that is evaluated to determine
      whether to evaluate THEN or ELSE.

    then:

      The statement to evaluate if predicate is true.

    else:

      The statement to evaluate if predicate is false.

  S_FOR:

    value: (names expression statement)

    names:

      A list of tokens that are bound variables.

    expression:

      The expression of what is being iterated over.

    statement:

      The expression to run in this for loop.

  S_WHILE:

    value: (predicate statement)

    predicate:

      The expression to test if the loop should be run.

    statement:

      The statement that is run each iteration.

  S_BREAK:

    value: ()

  S_CONTINUE:

    value: ()

  S_EXPRESSION:

    value: (expression)

    expression:

      The expression to evaluate as a statement.
      See `zenscript--parse-statement`."
  (let ((next (zenscript--peek-token tokens)))
    (pcase (car next)
      ('T_AOPEN
       (zenscript--get-token tokens)
       (let (statements)
	 (while (not (zenscript--optional-token 'T_ACLOSE tokens))
	   (cons! (zenscript--parse-statement tokens) statements))
	 (list 'S_BLOCK (reverse statements))))
      ('T_RETURN
       (zenscript--get-token tokens)
       (list 'S_RETURN
	     (prog1
		 (unless (eq 'T_SEMICOLON
			     (car (zenscript--peek-token tokens)))
		   (zenscript--parse-expression tokens))
	       (zenscript--require-token 'T_SEMICOLON tokens
					 "; expected"))))
      ((or 'T_VAR
	   'T_VAL)
       (zenscript--get-token tokens)
       (let* ((id (zenscript--require-token 'T_ID tokens
					    "identifier expected"))
	      initializer
	      type)
	 (when (zenscript--optional-token 'T_AS tokens)
	   (setq type (zenscript--parse-zentype tokens)))
	 (when (zenscript--optional-token 'T_ASSIGN tokens)
	   (setq initializer (zenscript--parse-expression tokens)))
	 (zenscript--require-token 'T_SEMICOLON tokens
				   "; expected")
	 (list 'S_VAR name type initializer
	       (eq (car next)
		   'T_VAL))))
      ('T_IF
       (zenscript--get-token tokens)
       (list 'S_IF
	     (zenscript--parse-expression tokens)
	     (zenscript--parse-statement tokens)
	     (when (zenscript--optional-token 'T_ELSE tokens)
	       (zenscript--parse-statement tokens))
	     (caddr next)))
      ('T_FOR
       (zenscript--get-token tokens)
       (list 'S_FOR
	     (let (break
		   names)
	       (cons! (zenscript--require-token 'T_ID tokens
						"identifier expected")
		      names)
	       (while (not break)
		 (if (zenscript--optional-token 'T_COMMA tokens)
		     (cons! (zenscript--require-token 'T_ID tokens
						      "identifier expected")
			    names)
		   (setq break t)))
	       (reverse names))
	     (progn
	       (zenscript--require-token 'T_IN tokens
					 "in expected")
	       (zenscript--parse-expression tokens))
	     (zenscript--parse-statement tokens)))
      ('T_WHILE
       (zenscript--get-token tokens)
       (list 'S_WHILE
	     (zenscript--parse-expression tokens)
	     (zenscript--parse-statement tokens)))
      ('T_BREAK
       (zenscript--get-token tokens)
       (zenscript--require-token 'T_SEMICOLON
				 "; expected")
       (list 'S_BREAK))
      ('T_CONTINUE
       (zenscript--get-token tokens)
       (zenscript--require-token 'T_SEMICOLON
				 "; expected")
       (list 'S_CONTINUE))
      (_
       (list 'S_EXPRESSION
	     (prog1 (zenscript--parse-expression tokens)
	       (zenscript--require-token 'T_SEMICOLON tokens
					 "; expected")))))))

(defun zenscript--parse-zentype (tokens)
  "Parse the next ZenType from TOKENS.

A ZenType is represented as a list of the following format:

 (category . value)

value:

  The value of the ZenType.  What `value` is depends on
  the type, described below.

category:

  A symbol, the category of the ZenType.
  This may be any of those below.  The format of
  `value` is also written for each entry:

  C_RAW: (name)

    A raw type is the simplest possible type.
    It has one value, its name, a string denoting
    its fully qualified name, as it may be imported
    or referenced without import.

    name:

      The name of the ZenType.

  C_FUNCTION: (argument-types return-type)

    A function type.  This is the type of
    a function object that can be called.

    argument-types:

      A list of ZenTypes that are the types
      of the function arguments.

    return-type:

      The ZenType returned by calling this function.

  C_LIST: (elem-type)

    A list type.  This would be equivalent to
    java.util.List<elem-type> in Java.

    elem-type:

      The ZenType of elements in the list.

  C_ARRAY: (elem-type)

    A Java array type.  This would be equivalent to
    elem-type[] in Java.

    elem-type:

      The ZenType of elements in the array.

  C_ASSOCIATIVE: (key-type val-type)

    A map type.  This would be equivalent to
    java.util.Map<key-type, val-type> in Java.

    key-type:

      The ZenType of keys in this map.

    val-type:

      The ZenType of values in this map.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((next (zenscript--get-token tokens))
	base)
    (pcase (car next)
      ('T_ANY (setq base '(C_RAW "any")))
      ('T_VOID (setq base '(C_RAW "void")))
      ('T_BOOL (setq base '(C_RAW "bool")))
      ('T_BYTE (setq base '(C_RAW "byte")))
      ('T_SHORT (setq base '(C_RAW "short")))
      ('T_INT (setq base '(C_RAW "int")))
      ('T_LONG (setq base '(C_RAW "long")))
      ('T_FLOAT (setq base '(C_RAW "float")))
      ('T_DOUBLE (setq base '(C_RAW "double")))
      ('T_STRING (setq base '(C_RAW "string")))
      ('T_ID
       (let ((type-name (cadr next)))
	 (while (zenscript--optional-token 'T_DOT tokens)
	   (setq type-name
		 (concat type-name "."
			 (cadr (zenscript--require-token 'T_ID tokens
							 "identifier expected")))))
	 (setq base (list 'C_RAW type-name))))
      ('T_FUNCTION
       (let (argument-types)
	 (zenscript--require-token 'T_BROPEN tokens
				   "( expected")
	 (unless (zenscript--optional-token 'T_BRCLOSE tokens)
	   (cons! (zenscript--parse-zentype tokens) argument-types)
	   (while (zenscript--optional-token 'T_COMMA tokens)
	     (cons! (zenscript--parse-zentype tokens) argument-types))
	   (zenscript--require-token 'T_BRCLOSE tokens
				     ") expected"))
	 (setq base (list 'C_FUNCTION (reverse argument-types) (zenscript--parse-zentype tokens)))))
      ('T_SQBROPEN
       (setq base (list 'C_LIST (zenscript--parse-zentype tokens)))
       (zenscript--require-token 'T_SQBRCLOSE tokens
				 "] expected"))
      (_ (throw 'zenscript-parse-error (format "Unknown type: %s" (cadr next)))))
    (while (zenscript--optional-token 'T_SQBROPEN tokens)
      (if (zenscript--optional-token 'T_SQBRCLOSE tokens)
	  (setq base (list 'C_ARRAY base))
	(setq base (list 'C_ASSOCIATIVE base (zenscript--parse-zentype tokens)))
	(zenscript--require-token 'T_SQBRCLOSE tokens
				  "] expected")))
    base))

(defun zenscript--parse-expression (tokens)
  "Parse the next expression from TOKENS.

An expression is a list of the form:

 (type . value)

type:

  The type of expression.  See below for possible expressions.

value:

  The value of the expression, varies by type.

Each layer of `zenscript--parse-<layer>` except the last
delegates to a layer below.  See each layer for
details on the possible expression types at each layer.


This layer delegates to `zenscript--parse-conditional`.

This layer reads the following expressions:

 (delegated) represents a function call to the next layer
 (recursive) represents a recursive call
 T_...       represents a token of the type T_...

  E_ASSIGN: (delegated) | T_ASSIGN | (recursive)
            v           | _        | v
            -----------------------------------
            left        | _        | right

    value: (left right)

  E_OPASSIGN: (delegated) | T_PLUSASSIGN  | (recursive)
              v           | O_PLUS        | v
              -----------------------------------------
              (delegated) | T_MINUSASSIGN | (recursive)
              v           | O_MINUS       | v
              -----------------------------------------
              (delegated) | T_TILDEASSIGN | (recursive)
              v           | O_TILDE       | v
              -----------------------------------------
              (delegated) | T_MULASSIGN   | (recursive)
              v           | O_MUL         | v
              -----------------------------------------
              (delegated) | T_DIVASSIGN   | (recursive)
              v           | O_DIV         | v
              -----------------------------------------
              (delegated) | T_MODASSIGN   | (recursive)
              v           | O_MOD         | v
              -----------------------------------------
              (delegated) | T_ORASSIGN    | (recursive)
              v           | O_OR          | v
              -----------------------------------------
              (delegated) | T_ANDASSIGN   | (recursive)
              v           | O_AND         | v
              -----------------------------------------
              (delegated) | T_XORASSIGN   | (recursive)
              v           | O_XOR         | v
              -----------------------------------------
              (delegated) | T_PLUSASSIGN  | (recursive)
              v           | O_PLUS        | v
              -----------------------------------------
              left        | op            | right

    value: (left right op)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((token (zenscript--peek-token tokens))
	position left)
    (unless token
      (throw 'zenscript-parse-error
	     "Unexpected end of file."))
    (setq position (caddr token))
    (setq left (zenscript--parse-conditional tokens))
    (unless (zenscript--peek-token tokens)
      (throw 'zenscript-parse-error
	     "Unexpected end of file."))

    (or (pcase (car (zenscript--peek-token tokens))
	  ('T_ASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_ASSIGN left (zenscript--parse-expression tokens)))
	  ('T_PLUSASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'ADD left (zenscript--parse-expression tokens)))
	  ('T_MINUSASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'SUB left (zenscript--parse-expression tokens)))
	  ('T_TILDEASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'CAT left (zenscript--parse-expression tokens)))
	  ('T_MULASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'MUL left (zenscript--parse-expression tokens)))
	  ('T_DIVASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'DIV left (zenscript--parse-expression tokens)))
	  ('T_MODASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'MOD left (zenscript--parse-expression tokens)))
	  ('T_ORASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'OR left (zenscript--parse-expression tokens)))
	  ('T_ANDASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'AND left (zenscript--parse-expression tokens)))
	  ('T_XORASSIGN
	   (zenscript--get-token tokens)
	   (list 'E_OPASSIGN 'XOR left (zenscript--parse-expression tokens)))
	  (_ ()))
	left)))

(defun zenscript--parse-conditional (tokens)
  "Possibly read a conditional expression from TOKENS.

This layer delegates to `zenscript--parse-or-or`.

This layer reads the following expressions:

 (delegated) represents a function call to the next layer
 (recursive) represents a recursive call
 T_...       represents a token of the type T_...

  E_CONDITIONAL: (delegated) | T_QUEST | (delegated) | T_COLON | (recursive)
                 v           | _       | v           | v       | v
                 -----------------------------------------------------------
                 predicate   | _       | then        | _       | else

    value: (predicate then else)

  ?: (delegated)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-or-or tokens)))
    (if-let (quest (zenscript--optional-token 'T_QUEST tokens))
	(list 'E_CONDITIONAL
	      left
	      (zenscript--parse-or-or tokens)
	      (progn (zenscript--require-token 'T_COLON tokens
					       ": expected")
		     (zenscript--parse-conditional tokens)))
      left)))

(defun zenscript--parse-binary (token-type expression-type tokens parse-next)
  "Convenience function for the binary expressions below.

TOKENS is the tokenstream to read from.

TOKEN-TYPE is the token representing this operation.

EXPRESSION-TYPE is the type of the expression that may
be parsed.

PARSE-NEXT is the function to delegate to."
  (let ((left (funcall parse-next tokens)))
    (while (zenscript--optional-token token-type tokens)
      (setq left
	    (list expression-type left
		  (funcall parse-next tokens))))
    left))

(defun zenscript--parse-or-or (tokens)
  "Possibly read an expression using ||s from TOKENS.

Delegates to `zenscript--parse-and-and`

Reads:

  E_OR2: (recursive) | T_OR2 | (delegated)
         v           |       | v
         ---------------------------------
         left        | _     | right

    value: (left right)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary 'T_OR2 'E_OR2 tokens
			   'zenscript--parse-and-and))

(defun zenscript--parse-and-and (tokens)
  "Possibly read an expression using &&s from TOKENS.

Delegates to `zenscript--parse-or`

Reads:

  E_AND2: (recursive) | T_AND2 | (delegated)
          v           |        | v
          ---------------------------------
          left        | _      | right

    value: (left right)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary 'T_AND2 'E_AND2 tokens
			   'zenscript--parse-or))

(defun zenscript--parse-or (tokens)
  "Possibly read an expression using |s from TOKENS.

Delegates to `zenscript--parse-xor`

Reads:

  E_OR (recursive) | T_OR | (delegated)
       v           |      | v
       ---------------------------------
       left        | _    | right

    value: (left right)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary 'T_OR 'E_OR tokens
			   'zenscript--parse-xor))

(defun zenscript--parse-xor (tokens)
  "Possibly read an expression using ^s from TOKENS.

Delegates to `zenscript--parse-and`

Reads:

  E_XOR (recursive) | T_XOR | (delegated)
        v           |       | v
        ---------------------------------
        left        | _     | right

    value: (left right)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary 'T_XOR 'E_XOR tokens
			   'zenscript--parse-and))

(defun zenscript--parse-and (tokens)
  "Possibly read an expression using &s from TOKENS.

Delegates to `zenscript--parse-comparison`

Reads:

  E_AND (recursive) | T_AND | (delegated)
        v           |       | v
        ---------------------------------
        left        | _     | right

    value: (left right)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (zenscript--parse-binary 'T_AND 'E_AND tokens
			   'zenscript--parse-comparison))

(defun zenscript--parse-comparison (tokens)
  "Possibly read a comparison expression from TOKENS.

Delegates to `zenscript--parse-add`

Reads:

  E_COMPARE: (delegated) | T_NOTEQ | (delegated)
             v           | C_EQ    | v
             -----------------------------------
             (delegated) | T_LT    | (delegated)
             v           | C_NE    | v
             -----------------------------------
             (delegated) | T_LTEQ  | (delegated)
             v           | C_LT    | v
             -----------------------------------
             (delegated) | T_GT    | (delegated)
             v           | C_LE    | v
             -----------------------------------
             (delegated) | T_GTEQ  | (delegated)
             v           | C_GT    | v
             -----------------------------------
             (delegated) | T_EQ    | (delegated)
             v           | C_GE    | v
             -----------------------------------
             left        | op      | right

    value: (left right op)

  E_BINARY: (delegated) | T_IN       | (delegated)
            v           | O_CONTAINS | v
            --------------------------------------
            left        | op         | right

    value: (left right op)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let* ((left (zenscript--parse-add tokens))
	 (type (pcase (car (zenscript--peek-token tokens))
		 ('T_EQ 'C_EQ)
		 ('T_NOTEQ 'C_NE)
		 ('T_LT 'C_LT)
		 ('T_LTEQ 'C_LE)
		 ('T_GT 'C_GT)
		 ('T_GTEQ 'C_GE)
		 ('T_IN
		  (setq left
			(list 'E_BINARY left
			      (progn
				(zenscript--get-token tokens)
				(zenscript--parse-add tokens))
			      'O_CONTAINS))
		  ;; doesn't count as a comparison
		  ;; but it's still here for some reason.
		  ()))))
    (if type
	(list 'E_COMPARE left
	      (progn
		(zenscript--get-token tokens)
		(zenscript--parse-add tokens))
	      type)
      left)))

(defun zenscript--parse-add (tokens)
  "Possibly read an addition-priority expression from TOKENS.

Delegates to `zenscript--parse-mul`

Reads:

  E_BINARY: (delegated) | T_MINUS | (delegated)
            v           | O_ADD   | v
            -----------------------------------
            (delegated) | T_TILDE | (delegated)
            v           | O_SUB   | v
            -----------------------------------
            (delegated) | T_PLUS  | (delegated)
            v           | O_CAT   | v
            -----------------------------------
            left        | op      | right

    value: (left right op)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-mul tokens)))
    (while (progn
	     (cond ((zenscript--optional-token 'T_PLUS tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_ADD)))
		   ((zenscript--optional-token 'T_MINUS tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_SUB)))
		   ((zenscript--optional-token 'T_TILDE tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-mul tokens)
				     'O_CAT)))
		   (t ()))))
    left))

(defun zenscript--parse-mul (tokens)
  "Possibly read an multiplication-priority expression from TOKENS.

Delegates to `zenscript--parse-unary`

Reads:

  E_BINARY: (delegated) | T_MUL | (delegated)
            v           | O_MUL | v
            ---------------------------------
            (delegated) | T_DIV | (delegated)
            v           | O_DIV | v
            ---------------------------------
            (delegated) | T_MOD | (delegated)
            v           | O_MOD | v
            ---------------------------------
            left        | op    | right

    value: (left right op)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((left (zenscript--parse-unary tokens)))
    (while (progn
	     (cond ((zenscript--optional-token 'T_MUL tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_MUL)))
		   ((zenscript--optional-token 'T_DIV tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_DIV)))
		   ((zenscript--optional-token 'T_MOD tokens)
		    (setq left (list 'E_BINARY left
				     (zenscript--parse-unary tokens)
				     'O_MOD)))
		   (t ()))))
    left))

(defun zenscript--parse-unary (tokens)
  "Possibly read a unary expression from TOKENS.

Delegates to `zenscript--parse-postfix`

Reads:

  E_UNARY: T_NOT   | (recursive)
           O_NOT   | v
           ---------------------
           T_MINUS | (recursive)
           O_MINUS | v
           ---------------------
           op      | expr

    value: (expr op)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (pcase (car (zenscript--peek-token tokens))
    ('T_NOT (list 'E_UNARY
		  (progn
		    (zenscript--get-token tokens)
		    (zenscript--parse-unary tokens))
		  'O_NOT))
    ('T_MINUS (list 'E_UNARY
		    (progn
		      (zenscript--get-token tokens)
		      (zenscript--parse-unary tokens))
		    'O_MINUS))
    (_ (zenscript--parse-postfix tokens))))

(defmacro ++ (val)
  "Increment VAL."
  `(setq ,val (1+ ,val)))

(defmacro += (val by)
  "Increment VAL by BY."
  `(setq ,val (+ ,val ,by)))

(defun zenscript--unescape-string (oldstr)
  "Unescape the string OLDSTR, i.e. get the value it represents.

unescape_perl_string()
<p>
Tom Christiansen <tchrist@perl.com> Sun Nov 28 12:55:24 MST 2010
<p>
It's completely ridiculous that there's no standard unescape_java_string
function.  Since I have to do the damn thing myself, I might as well make
it halfway useful by supporting things Java was too stupid to consider in
strings:
<p>
=> \"?\" items are additions to Java string escapes but normal in Java
regexes
<p>
=> \"!\" items are also additions to Java regex escapes
<p>
Standard singletons: ?\\a ?\\e \\f \\n \\r \\t
<p>
NB: \\b is unsupported as backspace so it can pass-through to the regex
translator untouched; I refuse to make anyone doublebackslash it as
doublebackslashing is a Java idiocy I desperately wish would die out.
There are plenty of other ways to write it:
<p>
\\cH, \\12, \\012, \\x08 \\x{8}, \\u0008, \\U00000008
<p>
Octal escapes: \\0 \\0N \\0NN \\N \\NN \\NNN Can range up to !\\777 not \\377
<p>
TODO: add !\\o{NNNNN} last Unicode is 4177777 maxint is 37777777777
<p>
Control chars: ?\\cX Means: ord(X) ^ ord('@')
<p>
Old hex escapes: \\xXX unbraced must be 2 xdigits
<p>
Perl hex escapes: !\\x{XXX} braced may be 1-8 xdigits NB: proper Unicode
never needs more than 6, as highest valid codepoint is 0x10FFFF, not
maxint 0xFFFFFFFF
<p>
Lame Java escape: \\[IDIOT JAVA PREPROCESSOR]uXXXX must be exactly 4
xdigits;
<p>
I can't write XXXX in this comment where it belongs because the damned
Java Preprocessor can't mind its own business. Idiots!
<p>
Lame Python escape: !\\UXXXXXXXX must be exactly 8 xdigits
<p>
TODO: Perl translation escapes: \\Q \\U \\L \\E \\[IDIOT JAVA PREPROCESSOR]u
\\l These are not so important to cover if you're passing the result to
Pattern.compile(), since it handles them for you further downstream. Hm,
what about \\[IDIOT JAVA PREPROCESSOR]u?"
  (let ((oldstr (substring oldstr 1 -1))
	string-builder
	saw-backslash)
    (dotimes (i (length oldstr))
      (let ((cp (aref oldstr i)))
	(if (not saw-backslash)
	    (if (eq cp ?\\)
		(setq saw-backslash t)
	      (cons! (char-to-string cp) string-builder))
	  (pcase cp
	    (?\\ (cons! "\\" string-builder))
	    (?r (cons! "\r" string-builder))
	    (?n (cons! "\n" string-builder))
	    (?f (cons! "\f" string-builder))
	    (?b (cons! "\\b" string-builder)) ; pass through
	    (?t (cons! "\t" string-builder))
	    (?a (cons! "\a" string-builder))
	    (?e (cons! "\e" string-builder))
	    ((or ?\' ?\") (cons! (char-to-string cp) string-builder))
	    (?c (++ i) (cons! (char-to-string (logxor (aref oldstr i 64))) string-builder))
	    ((or ?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9)
	     (unless (eq cp ?0) (+= i -1))
	     (if (eq (1+ i) (length oldstr))
		 (cons! "\0" string-builder)
	       (++ i)
	       (let ((digits 0))
		 (dotimes (j 3)
		   (if (eq (+ i j) (length oldstr))
		       (setq --dotimes-counter-- 3) ;; break
		     (let ((ch (aref oldstr (+ i j))))
		       (if (or (< ch ?0) (> ch ?7))
			   (setq --dotimes-counter-- 3) ;; break
			 (++ digits)))))
		 (let ((value (string-to-number (substring oldstr i (+ i digits)) 8)))
		   (cons! (char-to-string value) string-builder)
		   (+= i (1- digits))))))
	    (?x (++ i)
		(let (saw-brace chars)
		  (when (eq (aref oldstr i) ?\{)
		    (++ i)
		    (setq saw-brace t))
		  (dotimes (j 8)
		    (setq chars j)
		    (if (and (not saw-brace) (eq j 2))
			(setq --dotimes-counter-- 8) ;; break
		      (let ((ch (aref oldstr (+ i j))))
			(if (and saw-brace (eq ch ?\}))
			    (setq --dotimes-counter-- 8) ;; break
			  ))))
		  (let ((value (string-to-number (substring oldstr i (+ i chars)) 16)))
		    (cons! (char-to-string value) string-builder))
		  (when saw-brace
		    (++ chars))
		  (+= i (1- chars))))
	    (?u (++ i)
		(let ((value (string-to-number (substring oldstr i (+ i 4)) 16)))
		  (cons! (char-to-string value) string-builder))
		(+= i 4))
	    (?U (++ i)
		(let ((value (string-to-number (substring oldstr i (+ i 8)) 16)))
		  (cons! (char-to-string value) string-builder))
		(+= i 8))
	    (_ (cons! "\\" string-builder)
	       (cons! (char-to-string cp) string-builder)))
	  (setq --dotimes-counter-- i)
	  (setq saw-backslash ()))))

    (when saw-backslash
      ;; how
      (cons! "\\" string-builder))

    (apply 'concat (reverse string-builder))))

(defun zenscript--parse-postfix (tokens)
  "Possibly read a postfix expression from TOKENS.

Delegates to `zenscript--parse-primary`

  (expression) represents a call to `zenscript--parse-expression`
  (zentype) represents a call to `zenscript--parse-zentype`

Reads:

  E_MEMBER: (recursive) | T_DOT | T_ID
            v           | _     | (cadr v)
            -----------------------------------------------------------
            (recursive) | T_DOT | T_VERSION
            v           | _     | (cadr v)
            -----------------------------------------------------------
            (recursive) | T_DOT | T_STRING
            v           | _     | (zenscript--unescape-string (cadr v))
            -----------------------------------------------------------
            base        | _     | member

    value: (base member)

  E_BINARY: (recursive) | T_DOT2 | (expression)
            v           | _      | v
            -----------------------------------
            (recursive) | T_ID*  | (expression)
            v           | _      | v
            *only if (string= (cadr v) \"to\")
            -----------------------------------
            from        | _      | to

    value: (from to 'O_RANGE)

  E_INDEX: (recursive) | T_SQBROPEN | (expression) | T_SQBRCLOSE
           v           | _          | v            | _
           -----------------------------------------------------
           base        | _          | index        | _

    value: (base index)

  E_INDEX_SET: E_INDEX | T_ASSIGN | (expression)
               _       | _        | v
               ---------------------------------
               _       | _        | val

    A T_ASSIGN following an E_INDEX becomes an E_INDEX_SET.

    value: (base index val)

  E_CALL: (recursive) | T_BROPEN | [(expression) | ... T_COMMA] | T_BRCLOSE
          v           | _        | v                            | _
          -----------------------------------------------------------------
          base        | _        | args                         | _

    value: (base args)

  E_CAST: (recursive) | T_AS | (zentype)
          v           | _    | v
          ------------------------------
          base        | _    | type

    value: (base type)

  E_INSTANCEOF: (recursive) | T_INSTANCEOF | (zentype)
                v           | _            | v
                --------------------------------------
                base        | _            | type

    value: (base type)

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((base (zenscript--parse-primary tokens)))
    (while
	(and (zenscript--peek-token tokens)
	     (cond
	      ((zenscript--optional-token 'T_DOT tokens)
	       (let ((member (or (zenscript--optional-token 'T_ID tokens)
				 ;; what even is this
				 (zenscript--optional-token 'T_VERSION tokens))))
		 (setq base
		       (list 'E_MEMBER base
			     (if member
				 (cadr member)
			       (zenscript--unescape-string (cadr
							    ;; why
							    (or (zenscript--optional-token 'T_STRING tokens)
								(throw 'zenscript-parse-error
								       "Invalid expression.")))))))))
	      ((or (zenscript--optional-token 'T_DOT2 tokens)
		   (and (string-equal
			 "to"
			 (cadr (zenscript--optional-token 'T_ID tokens)))))
	       (setq base
		     (list 'E_BINARY base
			   (zenscript--parse-expression tokens)
			   'O_RANGE))
	       ())
	      ((zenscript--optional-token 'T_SQBROPEN tokens)
	       (let ((index (zenscript--parse-expression tokens)))
		 (zenscript--require-token 'T_SQBRCLOSE tokens
					   "] expected")
		 (setq base
		       (if (zenscript--optional-token 'T_ASSIGN tokens)
			   (list 'E_INDEX_SET base index (zenscript--parse-expression tokens))
			 (list 'E_INDEX base index)))))
	      ((zenscript--optional-token 'T_BROPEN tokens)
	       (let (arguments)
		 (when (not (zenscript--optional-token 'T_BRCLOSE tokens))
		   (cons! (zenscript--parse-expression tokens)
			  arguments)
		   (while (zenscript--optional-token 'T_COMMA tokens)
		     (cons! (zenscript--parse-expression tokens)
			    arguments))
		   (zenscript--require-token 'T_BRCLOSE tokens
					     ") expected"))
		 (setq base (list 'E_CALL base (reverse arguments)))))
	      ((zenscript--optional-token 'T_AS tokens)
	       (setq base (list 'E_CAST base (zenscript--parse-zentype tokens))))
	      ((zenscript--optional-token 'T_INSTANCEOF tokens)
	       (setq base (list 'E_INSTANCEOF base (zenscript--parse-zentype tokens))))
	      (t ()))))
    base))

(defun zenscript--decode-long (string)
  "Convert STRING to a number as java.lang.Long#decode would."
  (when (string-empty-p string)
    (throw 'number-format-exception "Zero length string"))
  (let ((radix 10)
	(index 0)
	negative
        (result 0))
    (cond ((eq (aref string 0)
	       ?\-)
	   (setq negative t)
	   (++ index))
	  ((eq (aref string 0)
	       ?\+)
	   (++ index)))
    (cond ((eq t (compare-strings string
				  index (+ index 2)
				  "0x"
				  0 2
				  t))
	   (setq radix 16)
	   (setq index (+ index 2)))
	  ((eq t (compare-strings string
				  index (+ index 1)
				  "#"
				  0 1))
	   (setq radix 16)
	   (++ index))
	  ((eq t (compare-strings string
				  index (+ index 1)
				  "0"
				  0 1))
	   (setq radix 8)
	   (++ index)))
    (when (or (eq t (compare-strings string
				     index (+ index 1)
				     "-"
				     0 1))
	      (eq t (compare-strings string
				     index (+ index 1)
				     "+"
				     0 1)))
      (throw 'number-format-exception "Sign character in wrong position"))
    (let ((result (string-to-number (substring string index) radix)))
      (if negative (- result) result))))

(defun zenscript--parse-primary (tokens)
  "Read a primary expression from TOKENS.

This is the last layer and does not delegate.

Reads:

  E_VALUE: _        | T_INTVALUE
           E_INT    | (zenscript--decode-long (cadr v))
           ---------|-------------------------------------
           _        | T_FLOATVALUE
           E_FLOAT  | (string-to-number (cadr v))
           ---------|-------------------------------------
           _        | T_STRINGVALUE
           E_STRING | (zenscript--unescape-string (cadr v))
           ---------|-------------------------------------
           type     | val

    value: (type val double-length?)

    double-length:

      If type is E_STRING, this is not present.

      If type is E_INT or E_FLOAT, this it t if a double-length
      Java primitive is represented here (long, double), and nil
      otherwise.

  E_VARIABLE: T_ID
              (cadr v)
              --------
              name

    value: (name)

  E_FUNCTION:

   T_FUNCTION | T_BROPEN | [T_ID | [T_AS (zentype)]? | ... T_COMMA]
   | T_BRCLOSE | [T_AS (zentype)]? | T_AOPEN | ... | T_ACLOSE

    An anonymous function.

    value: (arguments return-type statements)

      arguments:

        A list of arguments, of the form:

         (name type pos)

        name:

          The name of the argument, a string.

        type:

          The ZenType of the argument.

        pos:

          The pointer position the identifier token appeared at.

      return-type:

        The ZenType that this function returns.

      statements:

        A list of statements that are the function body.

  E_BRACKET: T_LT | ... | T_GT

    value: (tokens)

      tokens:

        A list of tokens that make up the bracket.

  E_LIST: T_SQBROPEN | [(expression) | ... T_COMMA] | T_SQBRCLOSE

    value: (elements)

      elements:

        A list of expressions that make up this list literal.

  E_MAP:

   T_AOPEN | [(expression) | T_COLON | (expression) | ... T_COMMA] | T_ACLOSE

    value: (keys values)

      keys:

        A list of expressions that are the keys of the map.

      values:

        A list of expressions that are the values of the map.

      The length of these two lists are the same, with each index of KEYS
      corresponding to the entry at the same index in VALUES.

  E_BOOL: T_TRUE
          t
          -------
          T_FALSE
          ()
          -------
          val

    value: (val)

      val:

        t if the boolean is TRUE, nil otherwise.

  E_NULL: T_NULL
          _
          ------
          _

    value: ()

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (pcase (car (zenscript--peek-token tokens))
    ('T_INTVALUE
     (let ((l (zenscript--decode-long (cadr (zenscript--get-token tokens)))))
       (list 'E_VALUE (list 'E_INT l (or (> l (- (expt 2 31) 1))
					 (< l (- (expt 2 31))))))))
    ('T_FLOATVALUE
     (let* ((value (cadr (zenscript--get-token tokens)))
	    (d (string-to-number value))
	    (lastchar (aref value (- (length value) 1))))
       (list 'E_VALUE (list 'E_FLOAT d (not (or (eq lastchar ?\f)
						(eq lastchar ?\F)))))))
    ('T_STRINGVALUE
     (list 'E_VALUE (list 'E_STRING (zenscript--unescape-string (cadr (zenscript--get-token tokens))))))
    ('T_ID
     (list 'E_VARIABLE (cadr (zenscript--get-token tokens))))
    ('T_FUNCTION
     (zenscript--get-token tokens)
     (let ((arguments (zenscript--parse-function-arguments tokens))
	   (return-type (if (zenscript--optional-token 'T_AS tokens)
			    (zenscript--parse-zentype tokens)
			  '(C_RAW "any")))
	   statements)
       (zenscript--require-token 'T_AOPEN tokens
				 "{ expected")
       (while (not (zenscript--optional-token 'T_ACLOSE tokens))
	 (cons! (zenscript--parse-statement tokens) statements))
       (list 'E_FUNCTION
	     arguments
	     return-type
	     (reverse statements))))
    ('T_LT
     (zenscript--get-token tokens)
     (let (btokens)
       (while (not (zenscript--optional-token 'T_GT tokens))
	 (cons! (zenscript--get-token tokens) btokens))
       (list 'E_BRACKET (reverse btokens))))
    ('T_SQBROPEN
     (zenscript--get-token tokens)
     (let (contents)
       (unless (zenscript--optional-token 'T_SQBRCLOSE tokens)
	 (let (break)
	   (while (and (not break)
		       (not (zenscript--optional-token 'T_SQBRCLOSE tokens)))
	     (cons! (zenscript--parse-expression tokens) contents)
	     (unless (zenscript--optional-token 'T_COMMA tokens)
	       (zenscript--require-token 'T_SQBRCLOSE tokens
					 "] or , expected")
	       (setq break t)))))
       (list 'E_LIST (reverse contents))))
    ('T_AOPEN
     (zenscript--get-token tokens)
     (let (keys values)
       (unless (zenscript--optional-token 'T_ACLOSE tokens)
	 (let (break)
	   (while (and (not break)
		       (not (zenscript--optional-token 'T_ACLOSE tokens)))
	     (cons! (zenscript--parse-expression tokens) keys)
	     (zenscript--require-token 'T_COLON tokens
				       ": expected")
	     (cons! (zenscript--parse-expression tokens) keys)
	     (unless (zenscript--optional-token 'T_COMMA tokens)
	       (zenscript--require-token 'T_ACLOSE tokens
					 "} or , expected")
	       (setq break t)))))
       (list 'E_MAP (reverse keys) (reverse values))))
    ('T_TRUE (zenscript--get-token tokens) (list 'E_BOOL t))
    ('T_FALSE (zenscript--get-token tokens) (list 'E_BOOL ()))
    ('T_NULL (zenscript--get-token tokens) (list 'E_NULL))
    ('T_BROPEN
     (zenscript--get-token tokens)
     (prog1 (zenscript--parse-expression tokens)
       (zenscript--require-token 'T_BRCLOSE tokens
				 ") expected")))
    (_ (throw 'zenscript-parse-error
	      "Invalid expression."))))

(defun zenscript--parse-global (tokens)
  "Parse the next global definition from TOKENS.

Return a list of the form:

 (name type value)

name:

  The token that is the name of this binding.

type:

  The ZenType of this binding.

value:

  The expression that is the initializer of this binding.

TOKENS must be a tokenstream from `zenscript--make-tokenstream`."
  (let ((name (zenscript--require-token 'T_ID tokens
					"Global value requires a name!"))
	(type (if (zenscript--optional-token 'T_AS tokens)
		  (zenscript--parse-zentype tokens)
		  '(C_RAW "any")))
	(value (progn (zenscript--require-token 'T_ASSIGN tokens
						"Global values have to be initialized!")
		      (zenscript--parse-expression tokens))))
    (zenscript--require-token 'T_SEMICOLON tokens
			      "; expected")
    (list name type value)))

(provide 'zenscript-language)
;;; zenscript-language.el ends here
