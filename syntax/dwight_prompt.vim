" Syntax highlighting for dwight prompt buffer (fallback — live extmarks do the real work)

if exists("b:current_syntax")
  finish
endif

syn match dwightSkillToken /@[a-zA-Z0-9_\-\.]\+/
syn match dwightModeToken /\/\(document\|refactor\|optimize\|fix_bugs\|security\|explain\|brainstorm\|code\|fix\)\>/
syn match dwightSymbolToken /#[a-zA-Z0-9_\-\.]\+/
syn match dwightSeparator /^[─═┌└│┐┘].*$/
syn match dwightInfoLabel /^\s*\(model\|skills\|modes\):/

hi def link dwightSkillToken DwightSkill
hi def link dwightModeToken DwightMode
hi def link dwightSymbolToken DwightSymbol
hi def link dwightSeparator Comment
hi def link dwightInfoLabel Comment

let b:current_syntax = "dwight_prompt"
