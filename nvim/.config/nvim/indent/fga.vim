" Vim indent file for the OpenFGA DSL (.fga)
"
"   model
"     schema 1.1
"
"   type document
"     relations
"       define viewer: [user] or editor
"
"   condition in_company_network(user_ip: ipaddress, cidr: string) {
"     user_ip.in_cidr(cidr)
"   }

if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal nolisp
setlocal nosmartindent
setlocal autoindent
setlocal indentexpr=FgaIndent()
setlocal indentkeys=0{,0},!^F,o,O,0=model,0=type,0=relations,0=define,0=condition,0=module,0=extend

if exists("*FgaIndent")
  finish
endif

let s:declaration = '^\s*\%(model\|type\|module\|extend\|condition\)\>'
let s:section = '^\s*\%(relations\|schema\)\>'

" Nearest line above {lnum} matching {pat}, or 0.
function! s:search(lnum, pat) abort
  let lnum = prevnonblank(a:lnum)
  while lnum > 0
    if getline(lnum) =~# a:pat
      return lnum
    endif
    let lnum = prevnonblank(lnum - 1)
  endwhile
  return 0
endfunction

" Indent of the innermost block that is still open at {lnum}, or -1.
function! s:body_indent(lnum) abort
  let open = s:search(a:lnum, '{\s*$')
  let relations = s:search(a:lnum, '^\s*relations\>')
  let declaration = s:search(a:lnum, s:declaration)

  if open > 0 && open > relations && open >= declaration
    return indent(open) + shiftwidth()
  endif
  if relations > 0 && relations > declaration
    return indent(relations) + shiftwidth()
  endif
  return -1
endfunction

function! FgaIndent() abort
  let lnum = v:lnum
  let prev = prevnonblank(lnum - 1)
  if prev == 0
    return 0
  endif

  let line = getline(lnum)
  let prevline = getline(prev)
  let sw = shiftwidth()

  " "}" closes a condition body: line back up with the "condition" line.
  if line =~# '^\s*}'
    let open = s:search(prev, '{\s*$')
    return open > 0 ? indent(open) : 0
  endif

  " Top level declarations are never indented.
  if line =~# s:declaration
    return 0
  endif

  " "relations" / "schema" sit one level inside their declaration.
  if line =~# s:section
    let head = s:search(prev, s:declaration)
    return head > 0 ? indent(head) + sw : 0
  endif

  " "define x: ..." sits one level inside "relations".
  if line =~# '^\s*define\>'
    let relations = s:search(prev, '^\s*relations\>')
    return relations > 0 ? indent(relations) + sw : sw
  endif

  " Comments belong to the body of the block they document.
  if prevline =~# '^\s*}'
    return indent(prev)
  endif

  let body = s:body_indent(prev)
  if body >= 0
    return body
  endif

  " Anything else continues the previous line's indentation.
  return indent(prev)
endfunction
