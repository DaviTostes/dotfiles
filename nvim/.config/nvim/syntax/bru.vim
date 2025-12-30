if exists("b:current_syntax")
  finish
endif

syn keyword brunoBlock meta get post put patch delete head options
syn keyword brunoBlock headers auth body script tests docs assert
syn keyword brunoBlock query params vars
syn keyword brunoBlock bru bruno res req

syn match brunoSectionLabel "\(auth\|body\|script\):\w\+"

syn match brunoComment "//.*$"
syn region brunoComment start="/\*" end="\*/"

syn region brunoString start='"' end='"' skip='\\"'
syn region brunoString start="'" end="'" skip="\\'"

syn match brunoVariable "{{\s*[^}]\+\s*}}"
syn match brunoUrlLine "^\s*url:\s*.*$" contains=brunoProperty,brunoUrl,brunoVariable
syn match brunoUrl "\(https\?\|wss\?\|http\?\)://[^\s{]*" contained

syn match brunoProperty "^\s*\w\+\s*:"
syn match brunoKey "\w\+\s*:"

syn match brunoNumber "\<\d\+\>"
syn match brunoBoolean "\<\(true\|false\)\>"
syn keyword brunoNull null undefined

syn keyword brunoFunction function return const let var if else for while test expect
syn keyword brunoAssertOp eq neq gt lt gte lte isDefined isNull isUndefined
syn keyword brunoMethod to equal be a an have include

syn match brunoBruAPI "\(setVar\|getVar\|setEnvVar\|getEnvVar\|deleteVar\|deleteEnvVar\)"
syn match brunoResAPI "\(status\|body\|headers\|responseTime\|statusText\|cookies\)"
syn match brunoReqAPI "\(url\|method\|headers\|body\)"

syn keyword brunoTypes string number boolean object array
syn keyword brunoHTTPMethod GET POST PUT PATCH DELETE HEAD OPTIONS

hi def link brunoBlock Keyword
hi def link brunoSectionLabel Type
hi def link brunoProperty Identifier
hi def link brunoKey Identifier
hi def link brunoComment Comment
hi def link brunoString String
hi def link brunoUrl Underlined
hi def link brunoNumber Number
hi def link brunoBoolean Boolean
hi def link brunoNull Constant
hi def link brunoFunction Function
hi def link brunoAssertOp Operator
hi def link brunoMethod Function
hi def link brunoVariable Special
hi def link brunoBruAPI Function
hi def link brunoResAPI Function
hi def link brunoReqAPI Function
hi def link brunoTypes Type
hi def link brunoHTTPMethod Constant

let b:current_syntax = "bruno"
