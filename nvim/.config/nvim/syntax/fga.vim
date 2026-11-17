" Vim syntax file
" Language:   OpenFGA authorization model DSL (.fga)
" Reference:  https://openfga.dev/docs/configuration-language

if exists("b:current_syntax")
  finish
endif

syn case match
" Condition bodies are multi-line regions, so jump-in parsing has to start at
" the top; models are small enough for that to stay cheap.
syn sync fromstart

" Comments ------------------------------------------------------------
syn match fgaComment "#.*$" contains=@Spell

" Keywords ------------------------------------------------------------
" model / schema 1.1 / type / relations / define / condition / module
syn keyword fgaKeyword model schema module extend type relations define
syn keyword fgaKeyword condition
syn match fgaKeyword "\<but\s\+not\>"
syn keyword fgaOperator or and from with

" Declarations --------------------------------------------------------
" Syntax patterns have no \zs, so the context is a look-behind.
syn match fgaSchemaVersion "\%(^\s*schema\s\+\)\@<=\d\+\.\d\+"
syn match fgaTypeName "\%(^\s*\%(type\|condition\)\s\+\)\@<=\h\w*"
syn match fgaModuleName "\%(^\s*module\s\+\)\@<=\h\w*"
syn match fgaRelationName "\%(^\s*define\s\+\)\@<=\h\w*"

" Type restrictions: [user], [user:*], [group#member], [user with cond]
syn region fgaTypeRestriction start="\[" end="\]" contains=fgaTypeRef,fgaUsersetRel,fgaWildcard,fgaCondWith
syn match fgaTypeRef "\h\w*" contained
syn match fgaUsersetRel "#\h\w*" contained
syn match fgaWildcard "\*" contained
syn keyword fgaCondWith with contained

" Condition bodies are CEL expressions ---------------------------------
syn region fgaConditionBody matchgroup=fgaBraces start="{" end="}"
      \ contains=fgaComment,fgaString,fgaCelNumber,fgaCelOperator,fgaCelKeyword,fgaCelBuiltin,fgaCelCall
syn match fgaCelOperator "&&\|||\|==\|!=\|<=\|>=\|[<>!+\-*/%?:]" contained
syn keyword fgaCelKeyword true false null in contained
syn match fgaCelBuiltin "\<\%(ipaddress\|timestamp\|duration\|double\|string\|bytes\|bool\|list\|map\|int\|uint\)\>" contained
syn match fgaCelCall "\<\h\w*\(\s*(\)\@=" contained

" Literals ------------------------------------------------------------
syn region fgaString start=+"+ skip=+\\"+ end=+"+ contains=@Spell
syn region fgaString start=+'+ skip=+\\'+ end=+'+
syn match fgaCelNumber "\<\d\+\%(\.\d\+\)\?\>" contained

" Highlighting --------------------------------------------------------
hi def link fgaComment Comment
hi def link fgaKeyword Keyword
hi def link fgaOperator Operator
hi def link fgaSchemaVersion Number
hi def link fgaTypeName Type
hi def link fgaModuleName Type
hi def link fgaRelationName Identifier
hi def link fgaTypeRestriction Delimiter
hi def link fgaTypeRef Type
hi def link fgaUsersetRel Special
hi def link fgaWildcard Special
hi def link fgaCondWith Keyword
hi def link fgaBraces Delimiter
hi def link fgaCelOperator Operator
hi def link fgaCelKeyword Constant
hi def link fgaCelBuiltin Type
hi def link fgaCelCall Function
hi def link fgaCelNumber Number
hi def link fgaString String

let b:current_syntax = "fga"
