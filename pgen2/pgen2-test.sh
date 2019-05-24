#!/bin/bash
#
# Figuring out if we can use pgen2 for Oil syntax.
#
# Usage:
#   ./pgen2-test.sh <function name>

# Things to parse:
# - Expressions
#   - same difficulties in shell arith parser: f(x,y), a[i+1], b ? a : b
#     - and our function calls will be more elaborate
#   - python features:
#     - list and dict comprehensions
#     - a not in b, a is not b
#     - a[1, 2] -- this is equivalent to tuple indexing?
#   - function literals, including the arg list syntax (which is complex)
#   - dict, set, tuple, list literals, which C parser doesn't have
#   - string and array literals, which need to invoke WordParser
#     - "${foo:-}" and [a b "$foo"]
#     - although disallow ${} and prefer $[] for expressions?
#   - floating point literals?
#   - including regex dialect?  (But that changes lexer modes)
# - Types:
#   - Optional type declarations with MyPy-ish syntax
#   - casting ("x as Int" like Rust?)
# - Other:
#   - classes, record, enum declarations!  Unlike funcs and procs, these do
#     NOT call back into the OSH parser.  There can be no statements inside
#     "class", etc.
#   - awk dialect: BEGIN / END / when.  Ditto, no arbitrary statements.
#   - 'rule' blocks: colon and other bells and whistles
#   - find dialect: fs ()
#
# Entry points:
# - var a = ...             # once you see var/const/set, switch
# - proc copy [src dest] {  # once you see proc, switch.  { switches back.
# - func f(name Str, age List<int>) List<int> {     # ditto, { switches back.
# - $stringfunc(x, y)       # once you see SmipleVarSub and look ahead to '('
#                           # then switch
# - @arrayfunc(x, y)        # hm this is harder?  Because oil-splice is
#                           # detected
#
# Exit Points:
# - a = [foo bar]                       # array literals go back to word parser
#   - but NOT a = List [
# - a = '    and "
#   a = $'   or %c''                    # not sure if we want $''
#   a = '''  # multiline?               # string literals back to word parser
# - block {                             # goes back to CommandParser
#   - but NOT { for dicts/sets
#
# Lexer Modes
#
# - lex_mode_e.Expr -- newlines are whitespace
# - lex_mode_e.Block -- newlines are terminators
# - lex_mode_e.CharClass -- regex char classes have different rules
#   (outer regexes use Expr mode, I believe)
# - lex_mode_e.TypeExpr -- because I hit the >> problem! 
#                          >> is not an operator in type expressions
# - lex_mode_e.Str    # simple double-quoted string literal?
#                     # I don't want all the mess
#                     # or you can post-process the LST and eliminate
#                     # undesirable shellc onstructs
#
# Extensions to pgen:
# - take tokens from a different lexer -- see NOTES-pgen2.txt for syntax ideas
# - callbacks to invoke the parser
#   - hm actually the "driver" can do this because it sees all the tokens?
#   - it's pushing rather than pulling.
#
# TODO: 
# - get rid of cruft and see what happens
# - write exhaustive test cases and get rid of arglist problem
#   - although you are going to change it to be honest
# - hook it up to Zephyr ASDL.  Create a convert= function.
#   - This is called on shift() and pop() in pgen2/parse.py.  You can look
#     at (typ, value) to figure out what to put in the LST.
#
# Construct an ambiguous grammar and see what happens?

set -o nounset
set -o pipefail
set -o errexit

banner() {
  echo
  echo "----- $@ -----"
  echo
}

# Copied from run.sh
parse() {
  PYTHONPATH=. pgen2/pgen2_main.py parse "$@"
}

parse-exprs() {
  readonly -a exprs=(
    '1+2'
    '1 + 2 * 3'
    'x | ~y'
    '1 << x'
    'a not in b'
    'a is not b'
    '[x for x in a]'
    '[1, 2]'
    '{myset, a}'
    '{mydict: a, key: b}'
    '{x: dictcomp for x in b}'
    'a[1,2]'
    'a[i:i+1]'
  )
  for expr in "${exprs[@]}"; do
    parse pgen2/oil.grammar eval_input "$expr"
  done
}

parse-arglists() {
  readonly -a arglists=( 
    'a'
    'a,b'
    'a,b=1'
    # Hm this parses, although isn't not valid
    'a=1,b'
    'a, *b, **kwargs'

    # Hm how is this valid?

    # Comment:
    # "The reason that keywords are test nodes instead of NAME is that using
    # NAME results in an ambiguity. ast.c makes sure it's a NAME."
    #
    # Hm is the parsing model powerful enough?   
    # TODO: change it to NAME and figure out what happens.
    #
    # Python 3.6's grammar has more comments!

    # "test '=' test" is really "keyword '=' test", but we have no such token.
    # These need to be in a single rule to avoid grammar that is ambiguous
    # to our LL(1) parser. Even though 'test' includes '*expr' in star_expr,
    # we explicitly match '*' here, too, to give it proper precedence.
    # Illegal combinations and orderings are blocked in ast.c:
    # multiple (test comp_for) arguments are blocked; keyword unpackings
    # that precede iterable unpackings are blocked; etc.

    'a+1'
  )

  for expr in "${arglists[@]}"; do
    parse pgen2/oil.grammar arglist_input "$expr"
  done
}

parse-types() {
  readonly -a types=(
    'int'
    'str'
    'List<str>'
    'Tuple<str, int, int>'
    'Dict<str, int>'
    # aha!  Tokenizer issue
    #'Dict<str, Tuple<int, int>>'

    # Must be like this!  That's funny.  Oil will have lexer modes to solve
    # this problem!
    'Dict<str, Tuple<int, int> >'
  )
  for expr in "${types[@]}"; do
    parse pgen2/oil.grammar type_input "$expr"
  done
}

calc-test() {
  local -a types=(
    'a + 2'
    '1 + 2*3/4'  # operator precedence and left assoc

    # Uses string tokens
    #'"abc" + "def"'

    '2 ^ 3 ^ 4'  # right assoc
    'f(1, 2, 3)'
    'f(a[i], 2, 3)'

    'x < 3 and y <= 4'

    # bad token
    #'a * 3&4'
  )
  #types=('a+a')

  for expr in "${types[@]}"; do
    echo "$expr"
    parse pgen2/calc.grammar test_input "$expr"
  done
}

enum-test() {
  readonly -a enums=(
    # second alternative
    'for 3 a'
    'for 3 { a, b }'
    'for 3 a { a, b }'
    #'for'
    #'a'
  )
  for expr in "${enums[@]}"; do
    parse pgen2/enum.grammar eval_input "$expr"
  done
}

ll1-test() {
  readonly -a enums=(
    # second alternative
    'a'
    'a b'
    #'b'
  )
  for expr in "${enums[@]}"; do
    parse pgen2/enum.grammar ll1_test "$expr"
  done
}

all() {
  banner 'exprs'
  parse-exprs

  banner 'arglists'
  parse-arglists

  banner 'types'
  parse-types

  banner 'calc'
  calc-test
}

# Hm Python 3 has type syntax!  But we may not use it.
# And it has async/await.
# And walrus operator :=.
# @ matrix multiplication operator.

diff-grammars() {
  wc -l ~/src/languages/Python-*/Grammar/Grammar

  cdiff ~/src/languages/Python-{2.7.15,3.6.7}/Grammar/Grammar
}

"$@"